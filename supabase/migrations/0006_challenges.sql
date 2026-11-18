-- 0006: Time4God Challenge — person vs person, group vs group, church vs church,
-- and a church's own members-only challenge. Score = minutes given to God
-- (time_deposits) between the start and end dates; groups and churches are
-- compared by average minutes per member. Everything goes through RPCs.

create table public.challenges (
  id uuid primary key default gen_random_uuid(),
  invite_code text unique not null,
  kind text not null check (kind in ('person', 'group', 'church', 'church_open')),
  status text not null default 'pending' check (status in ('pending', 'active', 'declined', 'canceled')),
  title text check (char_length(title) <= 80),
  message text check (char_length(message) <= 280),
  start_date date not null,
  end_date date not null,
  created_by uuid not null references public.partners(id) on delete cascade,
  a_partner uuid references public.partners(id) on delete cascade,
  a_table uuid references public.tables(id) on delete cascade,
  a_church uuid references public.churches(id) on delete cascade,
  b_partner uuid references public.partners(id) on delete cascade,
  b_table uuid references public.tables(id) on delete cascade,
  b_church uuid references public.churches(id) on delete cascade,
  responded_by uuid references public.partners(id) on delete set null,
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  check (end_date >= start_date and end_date - start_date <= 84)
);
create index on public.challenges (created_by);
create index on public.challenges (a_church);
create index on public.challenges (b_church);

create table public.challenge_entrants (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  partner_id uuid not null references public.partners(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (challenge_id, partner_id)
);

alter table public.challenges enable row level security;
alter table public.challenge_entrants enable row level security;
-- No policies: members reach challenges only through the functions below.

-- ---------- helpers ----------
create or replace function private.challenge_members(c public.challenges, side int)
returns setof uuid language sql stable security definer set search_path = public as $$
  select c.a_partner where c.kind = 'person' and side = 1 and c.a_partner is not null
  union all select c.b_partner where c.kind = 'person' and side = 2 and c.b_partner is not null
  union all select m.partner_id from memberships m where c.kind = 'group' and m.status = 'verified'
    and m.table_id = case side when 1 then c.a_table else c.b_table end
  union all select m.partner_id from memberships m where c.kind = 'church' and m.status = 'verified'
    and m.church_id = case side when 1 then c.a_church else c.b_church end
  union all select e.partner_id from challenge_entrants e where c.kind = 'church_open' and side = 1 and e.challenge_id = c.id $$;

create or replace function private.challenge_stats(c public.challenges, side int, out total int, out members int)
language sql stable security definer set search_path = public as $$
  with m as (select * from private.challenge_members(c, side) as pid)
  select coalesce((select sum(d.minutes) from time_deposits d
                   where d.partner_id in (select pid from m) and d.voided_at is null
                     and d.activity_date between c.start_date and least(c.end_date, current_date)), 0)::int,
         (select count(*) from m)::int $$;

create or replace function private.challenge_side_name(c public.challenges, side int)
returns text language sql stable security definer set search_path = public as $$
  select case
    when c.kind = 'person' then (select p.first_name || coalesce(' ' || nullif(left(p.last_name, 1), '') || '.', '') from partners p where p.id = case side when 1 then c.a_partner else c.b_partner end)
    when c.kind = 'group' then (select t.name || ' · ' || ch.name from tables t join churches ch on ch.id = t.church_id where t.id = case side when 1 then c.a_table else c.b_table end)
    when c.kind = 'church' then (select ch.name from churches ch where ch.id = case side when 1 then c.a_church else c.b_church end)
    when c.kind = 'church_open' and side = 1 then (select ch.name from churches ch where ch.id = c.a_church)
  end $$;

create or replace function private.side_church(c public.challenges, side int)
returns uuid language sql stable security definer set search_path = public as $$
  select case c.kind
    when 'church' then case side when 1 then c.a_church else c.b_church end
    when 'church_open' then case side when 1 then c.a_church end
    when 'group' then (select t.church_id from tables t where t.id = case side when 1 then c.a_table else c.b_table end)
  end $$;

-- 1 or 2 if the signed-in member is on that side, else null
create or replace function private.my_challenge_side(c public.challenges)
returns int language sql stable security definer set search_path = public, private as $$
  select case
    when private.my_partner_id() in (select private.challenge_members(c, 1)) then 1
    when private.my_partner_id() in (select private.challenge_members(c, 2)) then 2
  end $$;

create or replace function private.can_see_challenge(c public.challenges)
returns boolean language sql stable security definer set search_path = public, private as $$
  select c.created_by = private.my_partner_id()
    or private.my_challenge_side(c) is not null
    or coalesce(private.is_church_admin(private.side_church(c, 1)), false)
    or coalesce(private.is_church_admin(private.side_church(c, 2)), false)
    or (c.kind = 'church_open' and exists (select 1 from memberships m where m.partner_id = private.my_partner_id() and m.church_id = c.a_church and m.status = 'verified')) $$;

-- The group a leader speaks for: their own group in a church they lead
create or replace function private.my_led_table()
returns uuid language sql stable security definer set search_path = public, private as $$
  select m.table_id from memberships m
  where m.partner_id = private.my_partner_id() and m.status = 'verified' and m.table_id is not null
    and (private.is_church_admin(m.church_id) or exists (select 1 from role_assignments r where r.user_id = auth.uid() and r.church_id = m.church_id and r.role = 'table_leader' and r.verified_at is not null and r.revoked_at is null))
  limit 1 $$;

create or replace function private.my_admin_church()
returns uuid language sql stable security definer set search_path = public as $$
  select r.church_id from role_assignments r
  where r.user_id = auth.uid() and r.role = 'church_admin' and r.church_id is not null and r.verified_at is not null and r.revoked_at is null
  order by r.verified_at limit 1 $$;

-- ---------- what this member may send ----------
create or replace function public.challenge_options()
returns json language plpgsql stable security definer set search_path = public, private as $$
declare s seasons; t uuid := private.my_led_table(); ch uuid := private.my_admin_church(); st date;
begin
  select * into s from seasons where active;
  st := greatest(coalesce(s.start_date, current_date), current_date);
  return json_build_object(
    'has_account', private.my_partner_id() is not null,
    'group_id', t, 'group_name', (select tb.name || ' · ' || c.name from tables tb join churches c on c.id = tb.church_id where tb.id = t),
    'church_id', ch, 'church_name', (select name from churches where id = ch),
    'season_name', s.name, 'default_start', st, 'default_end', st + 84);
end $$;

-- ---------- send ----------
create or replace function public.create_challenge(p_kind text, p_start date default null, p_end date default null, p_message text default null, p_title text default null)
returns text language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); s seasons; st date; en date; code text; t uuid; ch uuid;
begin
  if me is null then raise exception 'Create your account first.'; end if;
  if p_kind not in ('person', 'group', 'church', 'church_open') then raise exception 'Choose a kind of challenge.'; end if;
  if (select count(*) from challenges where created_by = me and status = 'pending') >= 25 then
    raise exception 'You have 25 challenges waiting for an answer. Cancel some before sending more.';
  end if;
  select * into s from seasons where active;
  st := coalesce(p_start, greatest(coalesce(s.start_date, current_date), current_date));
  en := coalesce(p_end, st + 84);
  if st < current_date then raise exception 'The start date can''t be in the past.'; end if;
  if en < st then raise exception 'The end date must be after the start date.'; end if;
  if en - st > 84 then raise exception 'A challenge can last up to 12 weeks.'; end if;
  code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  if p_kind = 'person' then
    insert into challenges (invite_code, kind, title, message, start_date, end_date, created_by, a_partner)
    values (code, 'person', nullif(trim(p_title), ''), nullif(trim(p_message), ''), st, en, me, me);
  elsif p_kind = 'group' then
    t := private.my_led_table();
    if t is null then raise exception 'Only a group leader who belongs to a group can send a group challenge.'; end if;
    insert into challenges (invite_code, kind, title, message, start_date, end_date, created_by, a_table)
    values (code, 'group', nullif(trim(p_title), ''), nullif(trim(p_message), ''), st, en, me, t);
  else
    ch := private.my_admin_church();
    if ch is null then raise exception 'Only a church admin can send a church challenge.'; end if;
    insert into challenges (invite_code, kind, status, title, message, start_date, end_date, created_by, a_church)
    values (code, p_kind, case when p_kind = 'church_open' then 'active' else 'pending' end,
            coalesce(nullif(trim(p_title), ''), case when p_kind = 'church_open' then 'Time4God Challenge' end),
            nullif(trim(p_message), ''), st, en, me, ch);
  end if;
  return code;
end $$;

-- ---------- what an invitation link shows ----------
create or replace function public.challenge_preview(p_code text)
returns json language plpgsql stable security definer set search_path = public, private as $$
declare c challenges; me uuid := private.my_partner_id(); can boolean := false; why text; t uuid; ch uuid;
begin
  select * into c from challenges where invite_code = upper(trim(p_code));
  if c.id is null then return null; end if;
  if c.kind = 'church_open' then
    can := false; why := 'This challenge is for members of ' || private.challenge_side_name(c, 1) || '. Members join it in the app.';
  elsif c.status <> 'pending' then
    why := case c.status when 'active' then 'This challenge has already been accepted.' when 'declined' then 'This challenge was declined.' else 'This challenge was canceled.' end;
  elsif auth.uid() is null then
    why := 'Sign in to accept.';
  elsif me is null then
    why := 'Create your account first.';
  elsif c.created_by = me then
    why := 'You sent this challenge. Share the link with the person you want to challenge.';
  elsif c.kind = 'person' then
    can := true;
  elsif c.kind = 'group' then
    t := private.my_led_table();
    if t is null then why := 'Only a group leader can accept a group challenge for their group.';
    elsif t = c.a_table then why := 'Your group sent this challenge.';
    else can := true; end if;
  elsif c.kind = 'church' then
    ch := private.my_admin_church();
    if ch is null then why := 'Only your church admin can accept a church challenge. Forward this link to them.';
    elsif ch = c.a_church then why := 'Your church sent this challenge.';
    else can := true; end if;
  end if;
  return json_build_object('kind', c.kind, 'status', c.status, 'title', c.title, 'message', c.message,
    'start_date', c.start_date, 'end_date', c.end_date, 'from_name', private.challenge_side_name(c, 1),
    'sender', (select first_name from partners where id = c.created_by),
    'can_accept', can, 'reason', why, 'id', case when can or c.created_by = me then c.id end);
end $$;

-- ---------- answer ----------
create or replace function public.respond_to_challenge(p_code text, p_accept boolean)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare c challenges; p json; me uuid := private.my_partner_id();
begin
  select * into c from challenges where invite_code = upper(trim(p_code)) for update;
  if c.id is null then raise exception 'That challenge was not found.'; end if;
  p := public.challenge_preview(p_code);
  if not (p->>'can_accept')::boolean then raise exception '%', coalesce(p->>'reason', 'You can''t answer this challenge.'); end if;
  if p_accept then
    update challenges set status = 'active', responded_by = me, responded_at = now(),
      b_partner = case when kind = 'person' then me end,
      b_table = case when kind = 'group' then private.my_led_table() end,
      b_church = case when kind = 'church' then private.my_admin_church() end
    where id = c.id;
  else
    update challenges set status = 'declined', responded_by = me, responded_at = now() where id = c.id;
  end if;
  return c.id;
end $$;

create or replace function public.cancel_challenge(p_id uuid)
returns void language plpgsql security definer set search_path = public, private as $$
declare c challenges;
begin
  select * into c from challenges where id = p_id;
  if c.id is null or not (c.created_by = private.my_partner_id() or (c.kind = 'church_open' and private.is_church_admin(c.a_church)) or private.is_platform_admin()) then
    raise exception 'Only the person who sent this challenge can cancel it.';
  end if;
  if c.status = 'pending' or (c.kind = 'church_open' and c.status = 'active') then
    update challenges set status = 'canceled' where id = p_id;
  else
    raise exception 'Only a challenge that hasn''t been accepted yet can be canceled.';
  end if;
end $$;

create or replace function public.join_challenge(p_id uuid)
returns void language plpgsql security definer set search_path = public, private as $$
declare c challenges; me uuid := private.my_partner_id();
begin
  select * into c from challenges where id = p_id;
  if c.id is null or c.kind <> 'church_open' or c.status <> 'active' then raise exception 'That challenge isn''t open.'; end if;
  if c.end_date < current_date then raise exception 'That challenge has ended.'; end if;
  if not exists (select 1 from memberships m where m.partner_id = me and m.church_id = c.a_church and m.status = 'verified') then
    raise exception 'This challenge is for approved members of %.', private.challenge_side_name(c, 1);
  end if;
  insert into challenge_entrants (challenge_id, partner_id) values (p_id, me) on conflict do nothing;
end $$;

create or replace function public.leave_challenge(p_id uuid)
returns void language sql security definer set search_path = public, private as $$
  delete from challenge_entrants where challenge_id = p_id and partner_id = private.my_partner_id() $$;

-- ---------- lists ----------
create or replace function private.challenge_row(c public.challenges)
returns json language sql stable security definer set search_path = public, private as $$
  select json_build_object('id', c.id, 'kind', c.kind, 'status', c.status, 'title', c.title, 'message', c.message,
    'start_date', c.start_date, 'end_date', c.end_date, 'created_at', c.created_at,
    'phase', case when c.status <> 'active' then c.status when current_date < c.start_date then 'upcoming' when current_date > c.end_date then 'finished' else 'live' end,
    'a_name', private.challenge_side_name(c, 1), 'b_name', private.challenge_side_name(c, 2),
    'a', (select row_to_json(x) from private.challenge_stats(c, 1) x),
    'b', case when c.kind <> 'church_open' and c.status = 'active' then (select row_to_json(x) from private.challenge_stats(c, 2) x) end,
    'my_side', private.my_challenge_side(c),
    'is_sender', c.created_by = private.my_partner_id(),
    'invite_code', case when c.created_by = private.my_partner_id() and c.status = 'pending' then c.invite_code end,
    'can_manage', c.created_by = private.my_partner_id() or (c.kind = 'church_open' and coalesce(private.is_church_admin(c.a_church), false))) $$;

create or replace function public.my_challenges()
returns setof json language sql stable security definer set search_path = public, private as $$
  select private.challenge_row(c) from challenges c
  where private.can_see_challenge(c) and c.status <> 'canceled'
  order by c.start_date desc, c.created_at desc $$;

create or replace function public.admin_challenges()
returns setof json language sql stable security definer set search_path = public, private as $$
  select private.challenge_row(c) from challenges c where private.is_platform_admin()
  order by c.created_at desc $$;

-- Scoreboard detail. Person challenges: each side's minutes by day, shown only while the challenge runs.
-- Members-only church challenges: each member's total (the leaderboard).
create or replace function public.challenge_board(p_id uuid)
returns json language plpgsql stable security definer set search_path = public, private as $$
declare c challenges;
begin
  select * into c from challenges where id = p_id;
  if c.id is null or not (private.can_see_challenge(c) or private.is_platform_admin()) then raise exception 'That challenge was not found.'; end if;
  if c.kind = 'church_open' then
    return (select coalesce(json_agg(r order by r.total desc, r.name), '[]'::json) from (
      select p.first_name || coalesce(' ' || nullif(left(p.last_name, 1), '') || '.', '') as name, e.partner_id = private.my_partner_id() as me,
        coalesce((select sum(d.minutes) from time_deposits d where d.partner_id = e.partner_id and d.voided_at is null
          and d.activity_date between c.start_date and least(c.end_date, current_date)), 0)::int as total
      from challenge_entrants e join partners p on p.id = e.partner_id where e.challenge_id = c.id) r);
  end if;
  if c.kind = 'person' and c.status = 'active' and current_date between c.start_date and c.end_date then
    return (select coalesce(json_agg(r order by r.day desc), '[]'::json) from (
      select d.activity_date as day,
        sum(d.minutes) filter (where d.partner_id = c.a_partner)::int as a,
        sum(d.minutes) filter (where d.partner_id = c.b_partner)::int as b
      from time_deposits d where d.partner_id in (c.a_partner, c.b_partner) and d.voided_at is null
        and d.activity_date between c.start_date and current_date
      group by d.activity_date) r);
  end if;
  return '[]'::json;
end $$;

-- ---------- grants ----------
revoke all on public.challenges, public.challenge_entrants from anon;
revoke execute on all functions in schema private from public;
grant execute on all functions in schema private to authenticated;
do $$ declare f text; begin
  foreach f in array array['challenge_options()', 'create_challenge(text, date, date, text, text)', 'respond_to_challenge(text, boolean)',
    'cancel_challenge(uuid)', 'join_challenge(uuid)', 'leave_challenge(uuid)', 'my_challenges()', 'admin_challenges()', 'challenge_board(uuid)']
  loop execute format('revoke execute on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
-- The invitation page can show who sent a challenge before the person signs in.
revoke execute on function public.challenge_preview(text) from public;
grant execute on function public.challenge_preview(text) to anon, authenticated;
-- Keep the nightly job private (the blanket grant above would re-open it)
revoke execute on function private.refresh_participation() from authenticated, public;
