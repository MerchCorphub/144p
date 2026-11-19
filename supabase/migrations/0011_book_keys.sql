-- 0011: app edition for print readers. The printed book (IngramSpark/KDP) carries a book key and
-- the address time4god.app/redeem. Each reader proves they hold the book by answering a question
-- picked just for them: "On page 47, find the word 'cabinet'. What word comes right after it?"
-- The page and word are random per reader. A correct answer turns on a free 1-year app seat.
-- One claim per account per key. The platform admin uploads the print interior PDF so the app
-- knows the words on every printed page.

create table public.book_keys (
  id uuid primary key default gen_random_uuid(),
  code text unique not null check (code = upper(code) and char_length(code) between 4 and 30),
  label text,
  active boolean not null default true,
  ends_on date,
  max_claims int check (max_claims is null or max_claims > 0),
  created_at timestamptz not null default now()
);
alter table public.book_keys enable row level security;

create table public.print_pages (
  page int primary key check (page > 0),
  words text[] not null,
  updated_at timestamptz not null default now()
);
alter table public.print_pages enable row level security;

create table public.key_questions (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id) on delete cascade,
  key_id uuid not null references public.book_keys(id) on delete cascade,
  page int not null,
  anchor text not null,
  answer text not null,
  wrong int not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '20 minutes',
  solved_at timestamptz
);
create index on public.key_questions (partner_id, created_at desc);
alter table public.key_questions enable row level security;

create table public.key_claims (
  id uuid primary key default gen_random_uuid(),
  key_id uuid not null references public.book_keys(id) on delete cascade,
  partner_id uuid not null references public.partners(id) on delete cascade,
  page int,
  claimed_at timestamptz not null default now(),
  unique (key_id, partner_id)
);
alter table public.key_claims enable row level security;
-- No policies on these tables: everything goes through the functions below.

create or replace function private.norm_word(t text) returns text language sql immutable as $$
  select lower(regexp_replace(coalesce(t, ''), '[^[:alnum:]]', '', 'g')) $$;

create or replace function private.clean_word(t text) returns text language sql immutable as $$
  select regexp_replace(regexp_replace(coalesce(t, ''), '^[^[:alnum:]]+', ''), '[^[:alnum:]]+$', '') $$;

create or replace function private.usable_key(p_code text) returns public.book_keys
language plpgsql stable security definer set search_path = public as $$
declare k book_keys;
begin
  select * into k from book_keys where code = upper(regexp_replace(trim(coalesce(p_code, '')), '\s+', '', 'g'));
  if k.id is null or not k.active or (k.ends_on is not null and k.ends_on < current_date) then
    raise exception 'That book key isn''t valid. Check the key printed in your book.';
  end if;
  if k.max_claims is not null and (select count(*) from key_claims where key_id = k.id) >= k.max_claims then
    raise exception 'This book key has reached its limit. Please contact the 144(P) Plan team.';
  end if;
  return k;
end $$;

-- Step 1: check the key and get a question for this reader
create or replace function public.redeem_start(p_code text) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); k book_keys; pg print_pages; lo int; hi int; tries int := 0;
  cands int[]; i int; q uuid; n int;
begin
  if me is null then raise exception 'Create your account first.'; end if;
  k := private.usable_key(p_code);
  if exists (select 1 from key_claims where key_id = k.id and partner_id = me) or private.has_individual_seat(me) then
    raise exception 'You already have the app edition. Open the app to start reading.';
  end if;
  if (select count(*) from key_questions where partner_id = me and created_at > now() - interval '1 hour') >= 6 then
    raise exception 'Too many tries for now. Please try again in an hour.';
  end if;
  select min(page), max(page) into lo, hi from print_pages;
  if lo is null then raise exception 'The app edition isn''t set up yet. Please try again soon.'; end if;
  -- skip the opening and closing pages; pick a random page with a word that appears only once on it
  loop
    tries := tries + 1;
    exit when tries > 25;
    select * into pg from print_pages
      where page between lo + least(10, (hi - lo) / 10) and hi - least(4, (hi - lo) / 20) and cardinality(words) >= 40
      order by random() limit 1;
    exit when pg.page is null;
    n := cardinality(pg.words);
    select array_agg(j) into cands from generate_subscripts(pg.words, 1) j
      where j < n and char_length(norm_word(pg.words[j])) >= 5 and char_length(norm_word(pg.words[j + 1])) >= 2
        and (select count(*) from unnest(pg.words) w where norm_word(w) = norm_word(pg.words[j])) = 1;
    if cands is not null then
      i := cands[1 + floor(random() * cardinality(cands))::int];
      update key_questions set expires_at = now() where partner_id = me and solved_at is null and expires_at > now();
      insert into key_questions (partner_id, key_id, page, anchor, answer)
      values (me, k.id, pg.page, clean_word(pg.words[i]), norm_word(pg.words[i + 1])) returning id into q;
      return json_build_object('question_id', q, 'page', pg.page, 'word', clean_word(pg.words[i]));
    end if;
  end loop;
  raise exception 'We couldn''t pick a page right now. Please try again.';
end $$;

-- Step 2: answer it. Three wrong answers end the question; the reader can ask for a new one.
create or replace function public.redeem_answer(p_question uuid, p_answer text) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); q key_questions; s seasons; ip uuid;
begin
  select * into q from key_questions where id = p_question and partner_id = me for update;
  if q.id is null then raise exception 'Question not found. Start again.'; end if;
  if q.solved_at is not null then return json_build_object('status', 'ok'); end if;
  if q.expires_at < now() or q.wrong >= 3 then raise exception 'This question has expired. Get a new one.'; end if;
  if norm_word(p_answer) <> q.answer then
    update key_questions set wrong = wrong + 1 where id = q.id;
    return json_build_object('status', case when q.wrong + 1 >= 3 then 'locked' else 'wrong' end, 'left', greatest(0, 2 - q.wrong));
  end if;
  select * into s from seasons where active limit 1;
  select id into ip from license_plans where kind = 'individual' order by sort_order limit 1;
  insert into individual_seats (partner_id, season_id, plan_id, price, status, paid_at, expires_at)
  values (me, s.id, ip, 0, 'active', now(), now() + interval '1 year')
  on conflict (partner_id, season_id) do update set status = 'active', price = 0, paid_at = now(), expires_at = now() + interval '1 year';
  insert into key_claims (key_id, partner_id, page) values (q.key_id, me, q.page) on conflict do nothing;
  update key_questions set solved_at = now() where id = q.id;
  insert into audit_logs (actor_id, action, resource_type, resource_id, metadata)
    values (auth.uid(), 'book_key.claimed', 'book_key', q.key_id::text, jsonb_build_object('page', q.page));
  return json_build_object('status', 'ok');
end $$;

-- ---------- platform admin ----------
create or replace function public.admin_print_pages_replace(p_pages jsonb) returns int
language plpgsql security definer set search_path = public, private as $$
declare n int;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can upload the print edition.'; end if;
  if jsonb_typeof(p_pages) <> 'array' or jsonb_array_length(p_pages) < 20 then raise exception 'That file doesn''t look like the full book interior.'; end if;
  delete from print_pages where true;
  insert into print_pages (page, words)
  select (e->>'page')::int, array(select jsonb_array_elements_text(e->'words'))
  from jsonb_array_elements(p_pages) e where (e->>'page')::int > 0;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.admin_print_status() returns json
language sql stable security definer set search_path = public, private as $$
  select case when private.is_platform_admin() then json_build_object(
    'pages', (select count(*) from print_pages), 'first', (select min(page) from print_pages), 'last', (select max(page) from print_pages),
    'words', (select coalesce(sum(cardinality(words)), 0) from print_pages), 'updated_at', (select max(updated_at) from print_pages)) end $$;

create or replace function public.admin_print_page(p_page int) returns text
language sql stable security definer set search_path = public, private as $$
  select array_to_string(words, ' ') from print_pages where page = p_page and private.is_platform_admin() $$;

create or replace function public.admin_book_keys() returns table (id uuid, code text, label text, active boolean, ends_on date, max_claims int, claims int, created_at timestamptz)
language sql stable security definer set search_path = public, private as $$
  select k.id, k.code, k.label, k.active, k.ends_on, k.max_claims, (select count(*)::int from key_claims c where c.key_id = k.id), k.created_at
  from book_keys k where private.is_platform_admin() order by k.created_at $$;

create or replace function public.admin_save_book_key(p_id uuid, p_code text, p_label text, p_active boolean, p_ends_on date, p_max_claims int) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare c text := upper(regexp_replace(trim(coalesce(p_code, '')), '\s+', '', 'g')); kid uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can manage book keys.'; end if;
  if c !~ '^[A-Z0-9-]{4,30}$' then raise exception 'Use 4 to 30 letters, numbers or dashes for the key.'; end if;
  if p_id is null then
    insert into book_keys (code, label, active, ends_on, max_claims) values (c, nullif(trim(p_label), ''), coalesce(p_active, true), p_ends_on, p_max_claims) returning id into kid;
  else
    update book_keys set code = c, label = nullif(trim(p_label), ''), active = coalesce(p_active, true), ends_on = p_ends_on, max_claims = p_max_claims where id = p_id returning id into kid;
  end if;
  return kid;
end $$;

create or replace function public.admin_key_claims() returns table (claimed_at timestamptz, code text, name text, email text, page int)
language sql stable security definer set search_path = public, private as $$
  select c.claimed_at, k.code, p.first_name || ' ' || p.last_name, p.email, c.page
  from key_claims c join book_keys k on k.id = c.key_id join partners p on p.id = c.partner_id
  where private.is_platform_admin() order by c.claimed_at desc limit 200 $$;

do $$ declare f text; begin
  foreach f in array array['redeem_start(text)', 'redeem_answer(uuid, text)', 'admin_print_pages_replace(jsonb)', 'admin_print_status()', 'admin_print_page(int)',
    'admin_book_keys()', 'admin_save_book_key(uuid, text, text, boolean, date, int)', 'admin_key_claims()']
  loop execute format('revoke execute on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
revoke execute on function private.usable_key(text) from public, anon;
grant execute on function private.usable_key(text), private.norm_word(text), private.clean_word(text) to authenticated;
