-- 0034: Family teen accounts and 4 guest seats a year.
--  * Any paid member (own seat, book key, church seat or church leader) can link up to 2 teens (ages 13–17), free.
--    Each teen has their own login. The teen's study book stays open while the parent's paid access lasts.
--    The parent can see the teen's time, challenges, notes and weekly reflections (the teen is told when accepting).
--    Teens can't add teens and don't get guest seats to give.
--  * Guest seats: a member with their own seat (bought or book key) can give up to 4 guest seats in any 12 months.

-- ---------- family links ----------
create table if not exists public.family_links (
  id uuid primary key default gen_random_uuid(),
  parent_partner_id uuid not null references public.partners(id) on delete cascade,
  teen_partner_id uuid references public.partners(id) on delete cascade,
  teen_name text not null, teen_email text,
  code text not null unique,
  created_at timestamptz not null default now(), accepted_at timestamptz, removed_at timestamptz, removed_by uuid
);
create index if not exists family_links_parent on public.family_links (parent_partner_id);
create unique index if not exists family_links_one_parent on public.family_links (teen_partner_id) where teen_partner_id is not null and removed_at is null;
alter table public.family_links enable row level security;
revoke all on public.family_links from anon, authenticated;

create or replace function private.family_max() returns int language sql immutable as $$ select 2 $$;
create or replace function private.guest_max_per_year() returns int language sql immutable as $$ select 4 $$;

-- Paid access a person has on their own (not through a parent)
create or replace function private.paid_access_base(pid uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select pid is not null and (
    private.has_individual_seat(pid)
    or exists (select 1 from memberships m where m.partner_id = pid and m.status = 'verified'
                 and (private.current_church_license(m.church_id)).status = 'active')
    or exists (select 1 from role_assignments r join partners p on p.auth_user_id = r.user_id
                 where p.id = pid and r.role in ('church_admin', 'table_leader') and r.verified_at is not null and r.revoked_at is null
                   and (private.current_church_license(r.church_id)).status = 'active')) $$;

-- The parent who covers this teen right now (null if none)
create or replace function private.family_parent(pid uuid) returns uuid
language sql stable security definer set search_path = public, private as $$
  select f.parent_partner_id from family_links f
  where f.teen_partner_id = pid and f.removed_at is null and f.accepted_at is not null and private.paid_access_base(f.parent_partner_id)
  limit 1 $$;

create or replace function private.family_access(pid uuid) returns boolean
language sql stable security definer set search_path = public, private as $$ select private.family_parent(pid) is not null $$;

create or replace function private.paid_access(pid uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.paid_access_base(pid) or private.family_access(pid) $$;

-- Reading access, "paid by" and guest seats
do $$
declare d text;
begin
  d := pg_get_functiondef('private.my_unlocked_week()'::regprocedure);
  d := replace(d, 'or coalesce(private.trial_until(pid) >= current_date, false)
      into ok;', 'or coalesce(private.trial_until(pid) >= current_date, false)
        or private.family_access(pid)
      into ok;');
  if position('family_access' in d) = 0 then raise exception 'my_unlocked_week not updated'; end if;
  execute d;

  d := pg_get_functiondef('private.member_paid_by(uuid)'::regprocedure);
  d := replace(d, 'when private.paid_access(pid) then ''leader'' end', 'when private.paid_access_base(pid) then ''leader''
    when private.family_access(pid) then ''family'' end');
  if position('''family''' in d) = 0 then raise exception 'member_paid_by not updated'; end if;
  execute d;

  d := pg_get_functiondef('public.respond_to_challenge(text,boolean)'::regprocedure);
  d := replace(d, 'if gp is null then raise exception ''The guest seat for this challenge was just used.',
    'if gp is null and private.guest_seats_left(c.created_by) > 0 then
        insert into guest_passes (owner_partner_id) values (c.created_by) returning id into gp;
      end if;
      if gp is null then raise exception ''The guest seat for this challenge was just used.');
  if position('insert into guest_passes (owner_partner_id) values (c.created_by)' in d) = 0 then raise exception 'respond_to_challenge not updated'; end if;
  execute d;
end $$;

create or replace function private.guest_seats_left(pid uuid) returns int
language sql stable security definer set search_path = public, private as $$
  select case when private.has_individual_seat(pid)
    then greatest(0, private.guest_max_per_year() - (select count(*)::int from guest_passes
           where owner_partner_id = pid and claimed_by is not null and claimed_at > now() - interval '1 year'))
    else 0 end $$;

-- ---------- family: the parent's side ----------
create or replace function public.my_family() returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object(
    'can_add', private.paid_access_base(private.my_partner_id()) and private.family_parent(private.my_partner_id()) is null,
    'max', private.family_max(),
    'teens', (select coalesce(json_agg(json_build_object('id', f.id, 'name', coalesce(t.first_name || ' ' || t.last_name, f.teen_name), 'invited_name', f.teen_name,
        'email', coalesce(t.email, f.teen_email), 'code', case when f.accepted_at is null then f.code end,
        'status', case when f.accepted_at is null then 'invited' else 'active' end, 'created_at', f.created_at, 'accepted_at', f.accepted_at) order by f.created_at), '[]'::json)
      from family_links f left join partners t on t.id = f.teen_partner_id
      where f.parent_partner_id = private.my_partner_id() and f.removed_at is null),
    'parent', (select json_build_object('id', f.id, 'name', p.first_name || ' ' || p.last_name, 'covered', private.paid_access_base(p.id), 'since', f.accepted_at)
      from family_links f join partners p on p.id = f.parent_partner_id
      where f.teen_partner_id = private.my_partner_id() and f.removed_at is null and f.accepted_at is not null limit 1),
    'guest_seats_left', private.guest_seats_left(private.my_partner_id()), 'guest_max', private.guest_max_per_year()) $$;

create or replace function public.family_invite(p_name text, p_email text, p_parent_ok boolean) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); p partners; em text := lower(nullif(trim(p_email), '')); c text; f family_links;
begin
  if me is null then raise exception 'Please sign in again.'; end if;
  if private.family_parent(me) is not null then raise exception 'Teen accounts can''t add other teens.'; end if;
  if not private.paid_access_base(me) then raise exception 'Teen accounts come with a paid membership. Get the study book first.'; end if;
  if not coalesce(p_parent_ok, false) then raise exception 'Please confirm you are the teen''s parent or legal guardian and that they are 13 to 17.'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Enter your teen''s first name.'; end if;
  if em is not null and not private.valid_email(em) then raise exception 'Check the email address.'; end if;
  select * into p from partners where id = me;
  if em is not null and em = lower(p.email) then raise exception 'Use your teen''s own email address, not yours.'; end if;
  if (select count(*) from family_links where parent_partner_id = me and removed_at is null) >= private.family_max() then
    raise exception 'You can link up to % teens. Remove one to add another.', private.family_max();
  end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from family_links where code = c);
  end loop;
  insert into family_links (parent_partner_id, teen_name, teen_email, code) values (me, trim(p_name), em, c) returning * into f;
  if em is not null then
    perform private.queue_email(em, h(p.first_name) || ' added you to their Time4God Challenge family',
      array['Hi ' || h(trim(p_name)) || ',',
            h(p.first_name || ' ' || p.last_name) || ' added you to their Time4God Challenge membership. You get the full 12-week study book, <em>What Will You Give Today?</em>, free, for as long as their membership lasts.',
            'Create your own free account (or sign in), then accept. Teen accounts are for ages 13 to 17. Your parent or guardian will be able to see the time you record, your challenges, and your notes and reflections.',
            'Your family code is <strong>' || c || '</strong>.'],
      'Accept and start reading', 'https://time4god.app/family.html?code=' || c,
      'You got this because ' || h(p.first_name) || ' entered your email. If this isn''t for you, ignore it.', 'family.invite');
  end if;
  return json_build_object('id', f.id, 'code', c, 'url', 'https://time4god.app/family.html?code=' || c);
end $$;

create or replace function public.family_remove(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); f family_links;
begin
  select * into f from family_links where id = p_id and removed_at is null for update;
  if f.id is null or me is null or (f.parent_partner_id <> me and f.teen_partner_id is distinct from me) then raise exception 'That family link was not found.'; end if;
  update family_links set removed_at = now(), removed_by = me where id = f.id;
end $$;

-- ---------- family: the teen's side ----------
create or replace function public.family_preview(p_code text) returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object('parent', p.first_name, 'teen_name', f.teen_name,
    'status', case when f.removed_at is not null then 'removed' when f.accepted_at is not null then 'used' when not private.paid_access_base(p.id) then 'inactive' else 'open' end,
    'mine', f.teen_partner_id is not null and f.teen_partner_id = private.my_partner_id(),
    'is_parent', f.parent_partner_id = private.my_partner_id())
  from family_links f join partners p on p.id = f.parent_partner_id where f.code = upper(trim(p_code)) $$;

create or replace function public.family_accept(p_code text, p_age_ok boolean) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); f family_links; p partners; t partners;
begin
  if me is null then raise exception 'Create your free account or sign in first.'; end if;
  if not coalesce(p_age_ok, false) then raise exception 'Teen accounts are for ages 13 to 17, with a parent''s permission. Please confirm.'; end if;
  select * into f from family_links where code = upper(trim(p_code)) for update;
  if f.id is null or f.removed_at is not null then raise exception 'That family code isn''t valid. Ask your parent to send a new one.'; end if;
  if f.parent_partner_id = me then raise exception 'This invitation is for your teen. Have them open it on their own account.'; end if;
  if f.accepted_at is not null then
    if f.teen_partner_id = me then return json_build_object('ok', true, 'already', true); end if;
    raise exception 'This family code was already used.';
  end if;
  if not private.paid_access_base(f.parent_partner_id) then raise exception 'Your parent''s membership isn''t active right now. Ask them to renew, then try again.'; end if;
  if private.family_parent(me) is not null or exists (select 1 from family_links where teen_partner_id = me and removed_at is null) then
    raise exception 'Your account is already linked to a parent.';
  end if;
  if exists (select 1 from family_links where parent_partner_id = me and removed_at is null) then raise exception 'A parent account can''t also be a teen account.'; end if;
  update family_links set teen_partner_id = me, accepted_at = now() where id = f.id;
  select * into p from partners where id = f.parent_partner_id;
  select * into t from partners where id = me;
  perform private.queue_email(p.email, h(t.first_name) || ' joined your Time4God Challenge family',
    array[h(t.first_name || ' ' || t.last_name) || ' accepted your invitation and can now read the full study book.',
          'You can see their time, challenges, notes and reflections under <strong>Get the Study Book › Family</strong>.'],
    'Open my family', 'https://time4god.app/access.html#family', null, 'family.joined');
  return json_build_object('ok', true, 'parent', p.first_name);
end $$;

-- ---------- what the parent can see ----------
create or replace function public.family_teen_view(p_link uuid) returns json
language plpgsql stable security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); f family_links; t partners; s seasons;
begin
  select * into f from family_links where id = p_link and removed_at is null and accepted_at is not null;
  if f.id is null or f.parent_partner_id <> me then raise exception 'That teen account was not found.'; end if;
  select * into t from partners where id = f.teen_partner_id;
  select * into s from seasons where active limit 1;
  return json_build_object(
    'name', t.first_name || ' ' || t.last_name, 'since', f.accepted_at,
    'week_minutes', (select coalesce(sum(minutes), 0) from time_deposits where partner_id = t.id and voided_at is null and activity_date >= date_trunc('week', current_date)::date),
    'season_minutes', (select coalesce(sum(minutes), 0) from time_deposits where partner_id = t.id and voided_at is null and (s.id is null or activity_date >= s.start_date)),
    'deposits', (select coalesce(json_agg(x order by x.activity_date desc, x.created_at desc), '[]'::json) from (
        select d.activity_date, d.activity_time, d.category::text as category, d.minutes, d.created_at, n.note
        from time_deposits d left join deposit_notes n on n.deposit_id = d.id
        where d.partner_id = t.id and d.voided_at is null order by d.activity_date desc, d.created_at desc limit 60) x),
    'reflections', (select coalesce(json_agg(json_build_object('week', r.week_start_date, 'meaningful', r.meaningful_time, 'next', r.next_week_plan) order by r.week_start_date desc), '[]'::json)
        from weekly_reflections r where r.partner_id = t.id),
    'challenges', (select coalesce(json_agg(json_build_object('kind', c.kind, 'status', c.status, 'start_date', c.start_date, 'end_date', c.end_date,
          'a', private.challenge_side_name(c, 1), 'b', private.challenge_side_name(c, 2)) order by c.start_date desc), '[]'::json)
        from challenges c where t.id in (c.a_partner, c.b_partner)));
end $$;

-- ---------- grants ----------
revoke execute on function private.family_max(), private.guest_max_per_year(), private.paid_access_base(uuid), private.family_parent(uuid), private.family_access(uuid) from public, anon;
grant execute on function private.family_max(), private.guest_max_per_year(), private.paid_access_base(uuid), private.family_parent(uuid), private.family_access(uuid) to authenticated;
revoke execute on function public.my_family(), public.family_invite(text, text, boolean), public.family_remove(uuid), public.family_accept(text, boolean), public.family_teen_view(uuid) from public, anon;
grant execute on function public.my_family(), public.family_invite(text, text, boolean), public.family_remove(uuid), public.family_accept(text, boolean), public.family_teen_view(uuid) to authenticated;
revoke execute on function public.family_preview(text) from public;
grant execute on function public.family_preview(text) to anon, authenticated;
