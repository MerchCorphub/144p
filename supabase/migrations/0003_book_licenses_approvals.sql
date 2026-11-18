-- 144(P) Plan — book reader, seat licenses, admin-set prices, group-leader approvals
-- Applied to project nkmdddossplaaswsqnxb on 2026-11-18

-- ---------- seasons (one active at a time) ----------
create table public.seasons (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  start_date date not null,
  join_cutoff date,
  active boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index seasons_one_active on public.seasons (active) where active;
insert into public.seasons (name, start_date, join_cutoff, active)
values ('Season 1 · Lent to Pentecost 2027', '2027-02-21', '2027-02-28', true);

-- ---------- license plans: prices the platform admin sets ----------
create table public.license_plans (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null check (kind in ('individual', 'church')),
  seat_limit int not null check (seat_limit > 0),
  price numeric(10,2) not null check (price >= 0),
  active boolean not null default true,
  sort_order int not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.license_plans (name, kind, seat_limit, price, sort_order) values
  ('Individual', 'individual', 1, 10, 1),
  ('Small group', 'church', 25, 225, 2),
  ('Ministry', 'church', 100, 800, 3),
  ('Church', 'church', 250, 1750, 4),
  ('Church-wide', 'church', 500, 3000, 5);

-- ---------- licenses ----------
create table public.church_licenses (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references public.churches(id) on delete cascade,
  season_id uuid not null references public.seasons(id) on delete cascade,
  plan_id uuid references public.license_plans(id) on delete set null,
  seats int not null check (seats > 0),
  price numeric(10,2) not null check (price >= 0),
  status text not null default 'pending_payment' check (status in ('pending_payment', 'active', 'canceled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (church_id, season_id)
);
create index on public.church_licenses (season_id);
create index on public.church_licenses (plan_id);

create table public.individual_seats (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id) on delete cascade,
  season_id uuid not null references public.seasons(id) on delete cascade,
  plan_id uuid references public.license_plans(id) on delete set null,
  price numeric(10,2) not null check (price >= 0),
  status text not null default 'pending_payment' check (status in ('pending_payment', 'active', 'canceled')),
  created_at timestamptz not null default now(),
  unique (partner_id, season_id)
);
create index on public.individual_seats (season_id);
create index on public.individual_seats (plan_id);

-- ---------- the book ----------
create table public.book_sections (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  title text not null,
  kind text not null default 'week',
  unlock_week int not null default 0 check (unlock_week between 0 and 12),
  sort_order int not null,
  content_html text not null default '',
  updated_at timestamptz not null default now()
);

-- ---------- helpers ----------
create or replace function private.active_season() returns public.seasons
language sql stable security definer set search_path = public as $$
  select * from seasons where active limit 1 $$;

create or replace function private.can_approve(cid uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.is_platform_admin() or private.is_church_admin(cid) or exists (
    select 1 from role_assignments where user_id = auth.uid() and church_id = cid
      and role = 'table_leader' and verified_at is not null and revoked_at is null) $$;

-- Highest week this person may read: -1 = no access, 0 = intro only, 1..12
create or replace function private.my_unlocked_week() returns int
language plpgsql stable security definer set search_path = public, private as $$
declare s seasons; pid uuid := private.my_partner_id(); ok boolean := false; w int;
begin
  if private.is_platform_admin() then return 12; end if;
  select * into s from seasons where active limit 1;
  if s.id is null then return -1; end if;
  if pid is not null then
    select exists (select 1 from memberships m join church_licenses l on l.church_id = m.church_id and l.season_id = s.id and l.status = 'active'
                   where m.partner_id = pid and m.status = 'verified')
        or exists (select 1 from individual_seats i where i.partner_id = pid and i.season_id = s.id and i.status = 'active')
      into ok;
  end if;
  if not ok then
    select exists (select 1 from role_assignments r join church_licenses l on l.church_id = r.church_id and l.season_id = s.id and l.status = 'active'
                   where r.user_id = auth.uid() and r.role in ('church_admin', 'table_leader') and r.verified_at is not null and r.revoked_at is null)
      into ok;
  end if;
  if not ok then return -1; end if;
  w := floor((current_date - s.start_date) / 7.0)::int + 1;
  return greatest(0, least(12, w));
end $$;

-- ---------- row-level security ----------
alter table public.seasons enable row level security;
alter table public.license_plans enable row level security;
alter table public.church_licenses enable row level security;
alter table public.individual_seats enable row level security;
alter table public.book_sections enable row level security;

create policy seasons_select on public.seasons for select to authenticated using (true);
create policy seasons_insert on public.seasons for insert to authenticated with check ((select private.is_platform_admin()));
create policy seasons_update on public.seasons for update to authenticated using ((select private.is_platform_admin())) with check ((select private.is_platform_admin()));
create policy seasons_delete on public.seasons for delete to authenticated using ((select private.is_platform_admin()));

create policy plans_select on public.license_plans for select to authenticated using (active or (select private.is_platform_admin()));
create policy plans_insert on public.license_plans for insert to authenticated with check ((select private.is_platform_admin()));
create policy plans_update on public.license_plans for update to authenticated using ((select private.is_platform_admin())) with check ((select private.is_platform_admin()));
create policy plans_delete on public.license_plans for delete to authenticated using ((select private.is_platform_admin()));

create policy clic_select on public.church_licenses for select to authenticated using (private.can_approve(church_id));
create policy clic_insert on public.church_licenses for insert to authenticated with check ((select private.is_platform_admin()));
create policy clic_update on public.church_licenses for update to authenticated using ((select private.is_platform_admin())) with check ((select private.is_platform_admin()));
create policy clic_delete on public.church_licenses for delete to authenticated using ((select private.is_platform_admin()));

create policy iseat_select on public.individual_seats for select to authenticated using (partner_id = (select private.my_partner_id()) or (select private.is_platform_admin()));
create policy iseat_update on public.individual_seats for update to authenticated using ((select private.is_platform_admin())) with check ((select private.is_platform_admin()));
create policy iseat_delete on public.individual_seats for delete to authenticated using ((select private.is_platform_admin()));
-- members request a seat only through request_individual_seat()

create policy book_select on public.book_sections for select to authenticated using (unlock_week <= (select private.my_unlocked_week()));
create policy book_insert on public.book_sections for insert to authenticated with check ((select private.is_platform_admin()));
create policy book_update on public.book_sections for update to authenticated using ((select private.is_platform_admin())) with check ((select private.is_platform_admin()));
create policy book_delete on public.book_sections for delete to authenticated using ((select private.is_platform_admin()));

-- ---------- RPCs ----------
-- Table of contents: titles only, never text
create or replace function public.book_toc()
returns table (slug text, title text, kind text, unlock_week int, sort_order int)
language sql stable security definer set search_path = public as $$
  select slug, title, kind, unlock_week, sort_order from book_sections order by sort_order $$;

create or replace function public.my_book_status()
returns table (unlocked_week int, season_name text, start_date date, join_cutoff date, membership text, church_name text, license_status text, seat_status text)
language plpgsql stable security definer set search_path = public, private as $$
declare s seasons; pid uuid := private.my_partner_id(); mst text; mcid uuid; mname text;
begin
  select * into s from seasons where active limit 1;
  select mm.status, mm.church_id, c.name into mst, mcid, mname from memberships mm join churches c on c.id = mm.church_id where mm.partner_id = pid and mm.status <> 'removed' limit 1;
  return query select private.my_unlocked_week(), s.name, s.start_date, s.join_cutoff, mst, mname,
    (select l.status from church_licenses l where l.church_id = mcid and l.season_id = s.id),
    (select i.status from individual_seats i where i.partner_id = pid and i.season_id = s.id);
end $$;

create or replace function public.join_church_by_code(p_code text)
returns text language plpgsql security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); ch churches; st text;
begin
  if pid is null then raise exception 'Create your account first.'; end if;
  select * into ch from churches where upper(code) = upper(trim(p_code));
  if ch.id is null then raise exception 'That church code was not found. Check it with your group leader.'; end if;
  select status into st from memberships where partner_id = pid and church_id = ch.id and status <> 'removed';
  if st is not null then return st; end if;
  update memberships set status = 'removed', table_id = null where partner_id = pid and status <> 'removed';
  st := case when ch.enrollment_policy = 'open' then 'verified' else 'pending' end;
  insert into memberships (partner_id, church_id, status, last_active_at) values (pid, ch.id, st, current_date);
  insert into audit_logs (actor_id, organization_id, action, resource_type) values (auth.uid(), ch.id, 'membership.requested', 'membership');
  return st;
end $$;

create or replace function public.request_individual_seat()
returns text language plpgsql security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); s seasons; p license_plans; st text;
begin
  if pid is null then raise exception 'Create your account first.'; end if;
  select * into s from seasons where active limit 1;
  if s.id is null then raise exception 'No season is open yet.'; end if;
  select * into p from license_plans where kind = 'individual' and active order by sort_order limit 1;
  if p.id is null then raise exception 'Individual seats are not available right now.'; end if;
  select status into st from individual_seats where partner_id = pid and season_id = s.id;
  if st is not null then return st; end if;
  insert into individual_seats (partner_id, season_id, plan_id, price) values (pid, s.id, p.id, p.price);
  return 'pending_payment';
end $$;

-- Churches this person can approve for
create or replace function public.my_leader_churches()
returns table (church_id uuid, name text, code text, role text)
language sql stable security definer set search_path = public, private as $$
  select c.id, c.name, c.code, case when private.is_platform_admin() then 'platform_admin' when private.is_church_admin(c.id) then 'church_admin' else 'table_leader' end
  from churches c where private.can_approve(c.id) order by c.name $$;

create or replace function public.church_seat_status(cid uuid)
returns table (plan_name text, seats int, used int, license_status text, season_name text)
language sql stable security definer set search_path = public, private as $$
  select p.name, l.seats, (select count(*)::int from memberships m where m.church_id = cid and m.status = 'verified'), l.status, s.name
  from seasons s left join church_licenses l on l.church_id = cid and l.season_id = s.id left join license_plans p on p.id = l.plan_id
  where s.active and private.can_approve(cid) $$;

create or replace function public.leader_members(cid uuid)
returns table (membership_id uuid, name text, email text, status text, joined_at date, is_leader boolean)
language sql stable security definer set search_path = public, private as $$
  select m.id, p.first_name || ' ' || p.last_name, p.email, m.status, m.joined_at,
    exists (select 1 from role_assignments r where r.user_id = p.auth_user_id and r.church_id = cid and r.role = 'table_leader' and r.verified_at is not null and r.revoked_at is null)
  from memberships m join partners p on p.id = m.partner_id
  where m.church_id = cid and m.status in ('pending', 'verified') and private.can_approve(cid)
  order by m.status desc, p.last_name, p.first_name $$;

-- Approve one or many. All or nothing: refuses if the church license would run out of seats.
create or replace function public.approve_memberships(p_ids uuid[])
returns int language plpgsql security definer set search_path = public, private as $$
declare cid uuid; n int; used int; cap int; s seasons;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  select min(church_id::text)::uuid, count(distinct church_id) into cid, n from memberships where id = any(p_ids) and status = 'pending';
  if n = 0 then return 0; end if;
  if n > 1 then raise exception 'Approve one church at a time.'; end if;
  if not private.can_approve(cid) then raise exception 'You are not a leader for this church.'; end if;
  perform pg_advisory_xact_lock(hashtext(cid::text));
  select count(*) into n from memberships where id = any(p_ids) and status = 'pending' and church_id = cid;
  select * into s from seasons where active limit 1;
  select seats into cap from church_licenses where church_id = cid and season_id = s.id and status <> 'canceled';
  if cap is not null then
    select count(*) into used from memberships where church_id = cid and status = 'verified';
    if used + n > cap then raise exception 'Only % seats are left on this church''s license. Approve fewer people or ask for more seats.', greatest(cap - used, 0); end if;
  end if;
  update memberships set status = 'verified' where id = any(p_ids) and status = 'pending' and church_id = cid;
  insert into audit_logs (actor_id, organization_id, action, resource_type, metadata) values (auth.uid(), cid, 'membership.approved', 'membership', jsonb_build_object('count', n));
  return n;
end $$;

create or replace function public.decline_memberships(p_ids uuid[])
returns int language plpgsql security definer set search_path = public, private as $$
declare cid uuid; n int;
begin
  select min(church_id::text)::uuid, count(distinct church_id) into cid, n from memberships where id = any(p_ids) and status = 'pending';
  if n = 0 then return 0; end if;
  if n > 1 then raise exception 'Decline one church at a time.'; end if;
  if not private.can_approve(cid) then raise exception 'You are not a leader for this church.'; end if;
  update memberships set status = 'removed' where id = any(p_ids) and status = 'pending' and church_id = cid;
  get diagnostics n = row_count;
  insert into audit_logs (actor_id, organization_id, action, resource_type, metadata) values (auth.uid(), cid, 'membership.declined', 'membership', jsonb_build_object('count', n));
  return n;
end $$;

-- Church admin names or removes a group leader (must already be a verified member)
create or replace function public.set_group_leader(p_membership uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public, private as $$
declare m memberships; uid_ uuid;
begin
  select * into m from memberships where id = p_membership and status = 'verified';
  if m.id is null then raise exception 'Only approved members can be group leaders.'; end if;
  if not (private.is_church_admin(m.church_id) or private.is_platform_admin()) then raise exception 'Only the church admin can name group leaders.'; end if;
  select auth_user_id into uid_ from partners where id = m.partner_id;
  if p_on then
    if not exists (select 1 from role_assignments where user_id = uid_ and church_id = m.church_id and role = 'table_leader' and revoked_at is null) then
      insert into role_assignments (user_id, church_id, role, verified_at) values (uid_, m.church_id, 'table_leader', now());
    end if;
  else
    update role_assignments set revoked_at = now() where user_id = uid_ and church_id = m.church_id and role = 'table_leader' and revoked_at is null;
  end if;
  insert into audit_logs (actor_id, organization_id, action, resource_type, resource_id) values (auth.uid(), m.church_id, case when p_on then 'leader.added' else 'leader.removed' end, 'membership', m.id::text);
end $$;

-- Platform admin: individual seat requests with names
create or replace function public.admin_individual_seats()
returns table (seat_id uuid, name text, email text, price numeric, status text, created_at timestamptz)
language sql stable security definer set search_path = public, private as $$
  select i.id, p.first_name || ' ' || p.last_name, p.email, i.price, i.status, i.created_at
  from individual_seats i join partners p on p.id = i.partner_id join seasons s on s.id = i.season_id and s.active
  where private.is_platform_admin() order by i.created_at desc $$;

-- ---------- grants ----------
revoke execute on all functions in schema private from public;
grant execute on all functions in schema private to authenticated;
do $$ declare f text; begin
  foreach f in array array['book_toc()', 'my_book_status()', 'join_church_by_code(text)', 'request_individual_seat()', 'my_leader_churches()',
    'church_seat_status(uuid)', 'leader_members(uuid)', 'approve_memberships(uuid[])', 'decline_memberships(uuid[])',
    'set_group_leader(uuid, boolean)', 'admin_individual_seats()']
  loop execute format('revoke execute on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
