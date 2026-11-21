-- 0024: book keys can skip the page-and-word question (Admin Panel › Book keys, per key).
-- Keys with the question still need the printed interior PDF uploaded. TABLE12 skips it.
alter table public.book_keys add column if not exists page_check boolean not null default true;
update public.book_keys set page_check = false where code = 'TABLE12';

-- Turns on the reader's app seat for a key (shared by both ways of claiming)
create or replace function private.claim_book_key(p_me uuid, p_key uuid, p_page int) returns void
language plpgsql security definer set search_path = public, private as $$
declare s seasons; ip uuid;
begin
  select * into s from seasons where active limit 1;
  select id into ip from license_plans where kind = 'individual' order by sort_order limit 1;
  insert into individual_seats (partner_id, season_id, plan_id, price, status, paid_at, expires_at)
  values (p_me, s.id, ip, 0, 'active', now(), now() + interval '1 year')
  on conflict (partner_id, season_id) do update set status = 'active', price = 0, paid_at = now(), expires_at = now() + interval '1 year';
  insert into key_claims (key_id, partner_id, page) values (p_key, p_me, p_page) on conflict do nothing;
  -- Give one: the printed book includes a seat to give
  insert into guest_passes (owner_partner_id, key_id) values (p_me, p_key) on conflict do nothing;
  insert into audit_logs (actor_id, action, resource_type, resource_id, metadata)
    values (auth.uid(), 'book_key.claimed', 'book_key', p_key::text, jsonb_build_object('page', p_page));
end $$;

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
  -- Keys set to skip the page question are claimed right away
  if not k.page_check then
    perform private.claim_book_key(me, k.id, null);
    return json_build_object('status', 'ok');
  end if;
  if (select count(*) from key_questions where partner_id = me and created_at > now() - interval '1 hour') >= 6 then
    raise exception 'Too many tries for now. Please try again in an hour.';
  end if;
  select min(page), max(page) into lo, hi from print_pages;
  if lo is null then raise exception 'The app edition isn''t set up yet. Please try again soon.'; end if;
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

create or replace function public.redeem_answer(p_question uuid, p_answer text) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); q key_questions;
begin
  select * into q from key_questions where id = p_question and partner_id = me for update;
  if q.id is null then raise exception 'Question not found. Start again.'; end if;
  if q.solved_at is not null then return json_build_object('status', 'ok'); end if;
  if q.expires_at < now() or q.wrong >= 3 then raise exception 'This question has expired. Get a new one.'; end if;
  if norm_word(p_answer) <> q.answer then
    update key_questions set wrong = wrong + 1 where id = q.id;
    return json_build_object('status', case when q.wrong + 1 >= 3 then 'locked' else 'wrong' end, 'left', greatest(0, 2 - q.wrong));
  end if;
  perform private.claim_book_key(me, q.key_id, q.page);
  update key_questions set solved_at = now() where id = q.id;
  return json_build_object('status', 'ok');
end $$;

drop function if exists public.admin_book_keys();
create function public.admin_book_keys() returns table (id uuid, code text, label text, active boolean, ends_on date, max_claims int, claims int, created_at timestamptz, page_check boolean)
language sql stable security definer set search_path = public, private as $$
  select k.id, k.code, k.label, k.active, k.ends_on, k.max_claims, (select count(*)::int from key_claims c where c.key_id = k.id), k.created_at, k.page_check
  from book_keys k where private.is_platform_admin() order by k.created_at $$;

drop function if exists public.admin_save_book_key(uuid, text, text, boolean, date, int);
create function public.admin_save_book_key(p_id uuid, p_code text, p_label text, p_active boolean, p_ends_on date, p_max_claims int, p_page_check boolean default true) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare c text := upper(regexp_replace(trim(coalesce(p_code, '')), '\s+', '', 'g')); kid uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can manage book keys.'; end if;
  if c !~ '^[A-Z0-9-]{4,30}$' then raise exception 'Use 4 to 30 letters, numbers or dashes for the key.'; end if;
  if p_id is null then
    insert into book_keys (code, label, active, ends_on, max_claims, page_check) values (c, nullif(trim(p_label), ''), coalesce(p_active, true), p_ends_on, p_max_claims, coalesce(p_page_check, true)) returning id into kid;
  else
    update book_keys set code = c, label = nullif(trim(p_label), ''), active = coalesce(p_active, true), ends_on = p_ends_on, max_claims = p_max_claims, page_check = coalesce(p_page_check, true)
    where id = p_id returning id into kid;
  end if;
  return kid;
end $$;

revoke execute on function private.claim_book_key(uuid, uuid, int) from public, anon, authenticated;
revoke execute on function public.admin_book_keys(), public.admin_save_book_key(uuid, text, text, boolean, date, int, boolean) from public, anon;
grant execute on function public.admin_book_keys(), public.admin_save_book_key(uuid, text, text, boolean, date, int, boolean) to authenticated;
