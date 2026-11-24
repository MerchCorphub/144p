-- 0038: Several seasons, which may overlap.
--  * seasons.active keeps meaning "the default season" (exactly one). seasons.listed = open for churches/people to choose.
--  * Each church or group picks its season (churches.season_id); its members read on that schedule.
--  * People without a church may pick their own (partners.season_id). Otherwise they follow the default.
--  * Paid access is still one year from payment, so after a season ends all 12 weeks stay open until the seat expires.
--  * Seats and licenses are not tied to a season choice.

alter table public.seasons add column if not exists listed boolean not null default true;
alter table public.churches add column if not exists season_id uuid references public.seasons(id) on delete set null;
alter table public.partners add column if not exists season_id uuid references public.seasons(id) on delete set null;

-- The church whose schedule a person follows: their verified church, else a church they lead
create or replace function private.schedule_church(pid uuid) returns uuid
language sql stable security definer set search_path = public, private as $$
  select coalesce(
    (select m.church_id from memberships m where m.partner_id = pid and m.status = 'verified' limit 1),
    (select r.church_id from role_assignments r join partners p on p.auth_user_id = r.user_id
       where p.id = pid and r.church_id is not null and r.role in ('church_admin', 'table_leader', 'account_manager') and r.verified_at is not null and r.revoked_at is null
       order by r.created_at limit 1)) $$;

create or replace function private.church_season(cid uuid) returns seasons
language sql stable security definer set search_path = public, private as $$
  select s.* from seasons s
  where s.id = coalesce((select season_id from churches where id = cid), (select id from seasons where active limit 1)) $$;

-- The season a person reads on
create or replace function private.season_for(pid uuid) returns seasons
language sql stable security definer set search_path = public, private as $$
  select s.* from seasons s where s.id = coalesce(
    (select c.season_id from churches c where c.id = private.schedule_church(pid)),
    (select season_id from partners where id = pid),
    (select id from seasons where active limit 1)) $$;

do $$
declare d text; f text;
begin
  foreach f in array array['private.my_unlocked_week()', 'public.my_book_status()', 'public.challenge_options()', 'private.reminder_content(uuid,date)', 'public.family_teen_view(uuid)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if f = 'public.challenge_options()' then
      d := replace(d, 'select * into s from seasons where active;', 'select * into s from private.season_for(me);');
    elsif f = 'public.family_teen_view(uuid)' then
      d := replace(d, 'select * into s from seasons where active limit 1;', 'select * into s from private.season_for(f.teen_partner_id);');
    else
      d := replace(d, 'select * into s from seasons where active limit 1;', 'select * into s from private.season_for(pid);');
    end if;
    if position('season_for(' in d) = 0 then raise exception '% not updated', f; end if;
    execute d;
  end loop;
  d := pg_get_functiondef('public.church_seat_status(uuid)'::regprocedure);
  d := replace(d, 'from seasons s left join lateral', 'from private.church_season(cid) s left join lateral');
  d := replace(d, 'where s.active and private.can_approve(cid)', 'where private.can_approve(cid)');
  if position('church_season(cid)' in d) = 0 then raise exception 'church_seat_status not updated'; end if;
  execute d;
end $$;

-- ---------- choosing ----------
create or replace function private.season_json(s seasons) returns json
language sql stable as $$
  select case when s.id is null then null else json_build_object('id', s.id, 'name', s.name, 'start_date', s.start_date, 'end_date', s.start_date + 83,
    'join_cutoff', s.join_cutoff, 'is_default', s.active,
    'phase', case when current_date < s.start_date then 'upcoming' when current_date <= s.start_date + 83 then 'live' else 'finished' end,
    'week', case when current_date < s.start_date then 0 else least(12, floor((current_date - s.start_date) / 7.0)::int + 1) end,
    'can_join', s.join_cutoff is null or s.join_cutoff >= current_date) end $$;

create or replace function public.list_seasons() returns json
language sql stable security definer set search_path = public, private as $$
  select coalesce(json_agg(private.season_json(s) order by s.start_date), '[]'::json) from seasons s
  where s.listed and (s.start_date + 83 >= current_date or s.active) $$;

create or replace function public.my_season() returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object(
    'season', private.season_json(private.season_for(private.my_partner_id())),
    'source', case when private.schedule_church(private.my_partner_id()) is not null
                     and (select season_id from churches where id = private.schedule_church(private.my_partner_id())) is not null then 'church'
                   when (select season_id from partners where id = private.my_partner_id()) is not null then 'own' else 'default' end,
    'church', (select name from churches where id = private.schedule_church(private.my_partner_id())),
    'chosen_id', (select season_id from partners where id = private.my_partner_id())) $$;

create or replace function public.set_my_season(p_season uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); s seasons;
begin
  if me is null then raise exception 'Please sign in again.'; end if;
  if p_season is not null then
    select * into s from seasons where id = p_season and listed;
    if s.id is null then raise exception 'That season isn''t available.'; end if;
    if s.join_cutoff is not null and s.join_cutoff < current_date and (select season_id from partners where id = me) is distinct from p_season then
      raise exception 'That season closed to new people on %.', to_char(s.join_cutoff, 'FMMonth FMDD');
    end if;
  end if;
  update partners set season_id = p_season where id = me;
  return public.my_season();
end $$;

create or replace function public.church_season_info(cid uuid) returns json
language sql stable security definer set search_path = public, private as $$
  select case when private.can_approve(cid) then json_build_object(
    'season', private.season_json(private.church_season(cid)), 'chosen_id', (select season_id from churches where id = cid),
    'can_change', private.manages_church(cid)) end $$;

create or replace function public.set_church_season(cid uuid, p_season uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare s seasons;
begin
  if not private.manages_church(cid) then raise exception 'Only the church admin can choose the season.'; end if;
  if p_season is not null then
    select * into s from seasons where id = p_season and listed;
    if s.id is null then raise exception 'That season isn''t available.'; end if;
  end if;
  update churches set season_id = p_season where id = cid;
  return public.church_season_info(cid);
end $$;

-- ---------- admin ----------
create or replace function public.admin_seasons() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see this.'; end if;
  return (select coalesce(json_agg(json_build_object('season', private.season_json(s), 'listed', s.listed,
      'churches', (select count(*) from churches c where c.season_id = s.id or (c.season_id is null and s.active and c.status = 'active')),
      'people', (select count(*) from partners p where (private.season_for(p.id)).id = s.id)) order by s.start_date), '[]'::json) from seasons s);
end $$;

create or replace function public.admin_save_season(p_id uuid, p_name text, p_start date, p_cutoff date, p_listed boolean) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare sid uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can change seasons.'; end if;
  if nullif(trim(p_name), '') is null or p_start is null then raise exception 'Give the season a name and a start date.'; end if;
  if p_cutoff is not null and p_cutoff < p_start - 365 then raise exception 'Check the last day to join.'; end if;
  if p_id is null then
    insert into seasons (name, start_date, join_cutoff, listed, active) values (trim(p_name), p_start, p_cutoff, coalesce(p_listed, true), not exists (select 1 from seasons where active)) returning id into sid;
  else
    update seasons set name = trim(p_name), start_date = p_start, join_cutoff = p_cutoff,
      listed = case when active then true else coalesce(p_listed, listed) end where id = p_id returning id into sid;
    if sid is null then raise exception 'Season not found.'; end if;
  end if;
  return sid;
end $$;

create or replace function public.admin_set_default_season(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can change seasons.'; end if;
  if not exists (select 1 from seasons where id = p_id) then raise exception 'Season not found.'; end if;
  update seasons set active = false where active and id <> p_id;
  update seasons set active = true, listed = true where id = p_id;
end $$;

revoke execute on function private.schedule_church(uuid), private.church_season(uuid), private.season_for(uuid), private.season_json(seasons) from public, anon;
grant execute on function private.schedule_church(uuid), private.church_season(uuid), private.season_for(uuid), private.season_json(seasons) to authenticated;
revoke execute on function public.list_seasons(), public.my_season(), public.set_my_season(uuid), public.church_season_info(uuid), public.set_church_season(uuid, uuid),
  public.admin_seasons(), public.admin_save_season(uuid, text, date, date, boolean), public.admin_set_default_season(uuid) from public, anon;
grant execute on function public.list_seasons(), public.my_season(), public.set_my_season(uuid), public.church_season_info(uuid), public.set_church_season(uuid, uuid),
  public.admin_seasons(), public.admin_save_season(uuid, text, date, date, boolean), public.admin_set_default_season(uuid) to authenticated;
