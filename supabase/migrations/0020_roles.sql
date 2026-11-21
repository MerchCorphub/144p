-- 0020: roles. (0020a added 'account_manager' to app_role.)
--  * Owner (Pete): the only one who can add or remove admins and account managers.
--  * Admins (platform_admin): everything else in the Admin Panel.
--  * Account managers: assigned to specific churches. For those churches only they can act as
--    church admin (approve members, groups, messages, buy seats), approve the church's request,
--    assign church admins, see codes/QR, set licenses by hand, and see the church's numbers and
--    payments. No prices, season, book, book keys, settings, or other churches.
--    An account manager has one role row with church_id null (the role itself) plus one row
--    per assigned church.

insert into public.app_settings (key, value) values ('owner_user_id', '51a17edf-589d-4e7b-8e25-b153843a332e')
on conflict (key) do nothing;

create or replace function private.is_owner() returns boolean
language sql stable security definer set search_path = public, private as $$
  select auth.uid() is not null and auth.uid()::text = private.setting('owner_user_id') and private.is_platform_admin() $$;

create or replace function private.is_account_manager(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select cid is not null and exists (select 1 from role_assignments where user_id = auth.uid() and church_id = cid
    and role = 'account_manager' and verified_at is not null and revoked_at is null) $$;

create or replace function private.is_any_account_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from role_assignments where user_id = auth.uid() and role = 'account_manager' and verified_at is not null and revoked_at is null) $$;

-- Account managers act as church admin for the churches assigned to them. Every church-scoped
-- permission (members, groups, messages, seats, invoices, payments) goes through this check.
create or replace function private.is_church_admin(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from role_assignments where user_id = auth.uid() and church_id = cid
    and role in ('church_admin', 'account_manager') and verified_at is not null and revoked_at is null) $$;

create or replace function public.my_leader_churches()
returns table (church_id uuid, name text, code text, role text)
language sql stable security definer set search_path = public, private as $$
  select c.id, c.name, c.code,
    case when private.is_platform_admin() then 'platform_admin' when private.is_account_manager(c.id) then 'account_manager'
         when private.is_church_admin(c.id) then 'church_admin' else 'table_leader' end
  from churches c where c.status = 'active' and private.can_approve(c.id) order by c.name $$;

create or replace function public.my_is_owner() returns boolean
language sql stable security definer set search_path = public, private as $$ select private.is_owner() $$;

-- ---------- licenses: account managers for their churches ----------
drop policy if exists clic_am_insert on public.church_licenses;
drop policy if exists clic_am_update on public.church_licenses;
drop policy if exists clic_am_delete on public.church_licenses;
create policy clic_am_insert on public.church_licenses for insert to authenticated with check (private.is_account_manager(church_id));
create policy clic_am_update on public.church_licenses for update to authenticated using (private.is_account_manager(church_id)) with check (private.is_account_manager(church_id));
create policy clic_am_delete on public.church_licenses for delete to authenticated using (private.is_account_manager(church_id));

-- ---------- church setup: scoped for account managers ----------
create or replace function public.admin_church_admins()
returns table (church_id uuid, user_id uuid, email text, name text, since timestamptz)
language sql stable security definer set search_path = public, private as $$
  select r.church_id, r.user_id, u.email::text,
         nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''), r.verified_at
  from role_assignments r
  join auth.users u on u.id = r.user_id
  left join partners p on p.auth_user_id = r.user_id
  where (private.is_platform_admin() or private.is_account_manager(r.church_id)) and r.role = 'church_admin' and r.church_id is not null
    and r.verified_at is not null and r.revoked_at is null
  order by r.verified_at $$;

-- Who manages which church (shown on the Churches tab)
create or replace function public.church_account_managers()
returns table (church_id uuid, user_id uuid, email text, name text)
language sql stable security definer set search_path = public, private as $$
  select r.church_id, r.user_id, u.email::text, nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), '')
  from role_assignments r join auth.users u on u.id = r.user_id left join partners p on p.auth_user_id = r.user_id
  where (private.is_platform_admin() or private.is_account_manager(r.church_id)) and r.role = 'account_manager' and r.church_id is not null
    and r.verified_at is not null and r.revoked_at is null $$;

create or replace function public.admin_set_church_admin(p_church uuid, p_email text, p_on boolean)
returns text language plpgsql security definer set search_path = public, private as $$
declare uid_ uuid; ch churches;
begin
  if not (private.is_platform_admin() or private.is_account_manager(p_church)) then raise exception 'Only an admin or this church''s account manager can assign church admins.'; end if;
  select * into ch from churches where id = p_church;
  if ch.id is null then raise exception 'That church was not found.'; end if;
  select id into uid_ from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if uid_ is null then
    raise exception 'No account uses % yet. Ask them to create an account in the 144(P) Plan app first, then add them again.', trim(p_email);
  end if;
  if p_on then
    if exists (select 1 from role_assignments where user_id = uid_ and church_id = p_church and role = 'church_admin' and revoked_at is null) then
      return 'already';
    end if;
    insert into role_assignments (user_id, church_id, role, verified_at) values (uid_, p_church, 'church_admin', now());
  else
    update role_assignments set revoked_at = now()
      where user_id = uid_ and church_id = p_church and role = 'church_admin' and revoked_at is null;
  end if;
  insert into audit_logs (actor_id, organization_id, action, resource_type, resource_id)
    values (auth.uid(), p_church, case when p_on then 'church_admin.added' else 'church_admin.removed' end, 'user', uid_::text);
  return case when p_on then 'added' else 'removed' end;
end $$;

create or replace function public.admin_org_requests()
returns table (id uuid, kind text, name text, city text, state text, phone text, website text, note text, requester text, email text, created_at timestamptz, status text)
language sql stable security definer set search_path = public, private as $$
  select c.id, c.kind, c.name, c.city, c.state, c.phone, c.website, c.request_note, p.first_name || ' ' || p.last_name, p.email, c.created_at, c.status
  from churches c left join partners p on p.id = c.requested_by
  where (private.is_platform_admin() or private.is_account_manager(c.id)) and c.status = 'pending' order by c.created_at $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.admin_decide_org(uuid, boolean)'::regprocedure);
  d := replace(d, $q$if not private.is_platform_admin() then raise exception 'Only the platform admin can approve churches.'; end if;$q$,
                  $q$if not (private.is_platform_admin() or private.is_account_manager(p_id)) then raise exception 'Only an admin or the account manager for this request can approve it.'; end if;$q$);
  if position('is_account_manager(p_id)' in d) = 0 then raise exception 'admin_decide_org was not updated'; end if;
  execute d;
end $$;

-- ---------- account manager overview: their churches' numbers ----------
create or replace function public.am_overview()
returns table (church_id uuid, name text, code text, kind text, status text, members bigint, pending bigint, groups bigint,
               seats int, license_status text, expires_at timestamptz, active_7 bigint, minutes_7 bigint, minutes_all bigint,
               paid_total numeric, open_invoices bigint, open_amount numeric, last_payment timestamptz)
language sql stable security definer set search_path = public, private as $$
  select c.id, c.name, c.code, c.kind, c.status,
    (select count(*) from memberships m where m.church_id = c.id and m.status = 'verified'),
    (select count(*) from memberships m where m.church_id = c.id and m.status = 'pending'),
    (select count(*) from tables t where t.church_id = c.id),
    l.seats, l.status, l.expires_at,
    (select count(distinct d.partner_id) from time_deposits d join memberships m on m.partner_id = d.partner_id and m.church_id = c.id and m.status = 'verified'
       where d.voided_at is null and d.activity_date > current_date - 7),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d join memberships m on m.partner_id = d.partner_id and m.church_id = c.id and m.status = 'verified'
       where d.voided_at is null and d.activity_date > current_date - 7),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d join memberships m on m.partner_id = d.partner_id and m.church_id = c.id and m.status = 'verified'
       where d.voided_at is null),
    (select coalesce(sum(p.amount), 0) from payments p where p.church_id = c.id and p.status = 'paid'),
    (select count(*) from payments p where p.church_id = c.id and p.method = 'invoice' and p.status = 'open' and p.stripe_invoice_id is not null),
    (select coalesce(sum(p.amount), 0) from payments p where p.church_id = c.id and p.method = 'invoice' and p.status = 'open' and p.stripe_invoice_id is not null),
    (select max(p.paid_at) from payments p where p.church_id = c.id and p.status = 'paid')
  from churches c left join lateral (select * from private.current_church_license(c.id)) l on true
  where private.is_account_manager(c.id)
  order by c.status = 'pending' desc, c.name $$;

-- ---------- roles (owner only) ----------
create or replace function public.admin_roles()
returns table (user_id uuid, email text, name text, role text, since timestamptz, is_owner boolean, churches json)
language sql stable security definer set search_path = public, private as $$
  select r.user_id, u.email::text, nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''), r.role::text, min(r.verified_at),
    r.user_id::text = private.setting('owner_user_id'),
    case when r.role = 'account_manager' then (select coalesce(json_agg(json_build_object('id', c.id, 'name', c.name, 'status', c.status) order by c.name), '[]'::json)
      from role_assignments x join churches c on c.id = x.church_id
      where x.user_id = r.user_id and x.role = 'account_manager' and x.revoked_at is null and x.verified_at is not null) end
  from role_assignments r join auth.users u on u.id = r.user_id left join partners p on p.auth_user_id = r.user_id
  where private.is_owner() and r.role in ('platform_admin', 'account_manager') and r.church_id is null and r.verified_at is not null and r.revoked_at is null
  group by r.user_id, u.email, p.first_name, p.last_name, r.role
  order by r.role, 3 $$;

create or replace function public.admin_add_role(p_email text, p_role text) returns text
language plpgsql security definer set search_path = public, private as $$
declare uid_ uuid;
begin
  if not private.is_owner() then raise exception 'Only the owner can add admins and account managers.'; end if;
  if p_role not in ('platform_admin', 'account_manager') then raise exception 'Choose Admin or Account manager.'; end if;
  select id into uid_ from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if uid_ is null then raise exception 'No account uses % yet. Ask them to create an account in the 144(P) Plan app first, then add them again.', trim(p_email); end if;
  if exists (select 1 from role_assignments where user_id = uid_ and role = p_role::app_role and church_id is null and revoked_at is null) then return 'already'; end if;
  insert into role_assignments (user_id, church_id, role, verified_at) values (uid_, null, p_role::app_role, now());
  insert into audit_logs (actor_id, action, resource_type, resource_id, metadata) values (auth.uid(), 'role.added', 'user', uid_::text, jsonb_build_object('role', p_role));
  return 'added';
end $$;

create or replace function public.admin_remove_role(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.is_owner() then raise exception 'Only the owner can remove admins and account managers.'; end if;
  if p_user::text = private.setting('owner_user_id') and p_role = 'platform_admin' then raise exception 'The owner can''t be removed as admin.'; end if;
  if p_role not in ('platform_admin', 'account_manager') then raise exception 'Unknown role.'; end if;
  -- For account managers this also removes every church assigned to them
  update role_assignments set revoked_at = now() where user_id = p_user and role = p_role::app_role and revoked_at is null;
  insert into audit_logs (actor_id, action, resource_type, resource_id, metadata) values (auth.uid(), 'role.removed', 'user', p_user::text, jsonb_build_object('role', p_role));
end $$;

create or replace function public.admin_set_am_churches(p_user uuid, p_churches uuid[]) returns int
language plpgsql security definer set search_path = public, private as $$
declare n int;
begin
  if not private.is_owner() then raise exception 'Only the owner can assign churches to account managers.'; end if;
  if not exists (select 1 from role_assignments where user_id = p_user and role = 'account_manager' and church_id is null and revoked_at is null and verified_at is not null) then
    raise exception 'That person isn''t an account manager.';
  end if;
  update role_assignments set revoked_at = now()
    where user_id = p_user and role = 'account_manager' and church_id is not null and revoked_at is null and not (church_id = any(coalesce(p_churches, '{}')));
  insert into role_assignments (user_id, church_id, role, verified_at)
    select p_user, c.id, 'account_manager', now() from churches c
    where c.id = any(coalesce(p_churches, '{}')) and c.status <> 'declined'
      and not exists (select 1 from role_assignments x where x.user_id = p_user and x.church_id = c.id and x.role = 'account_manager' and x.revoked_at is null);
  select count(*) into n from role_assignments where user_id = p_user and role = 'account_manager' and church_id is not null and revoked_at is null;
  insert into audit_logs (actor_id, action, resource_type, resource_id, metadata) values (auth.uid(), 'role.am_churches', 'user', p_user::text, jsonb_build_object('count', n));
  return n;
end $$;

-- Every church (including requests waiting) for the owner's assignment checklist
create or replace function public.admin_all_churches()
returns table (id uuid, name text, status text, kind text, city text, state text)
language sql stable security definer set search_path = public, private as $$
  select id, name, status, kind, city, state from churches where private.is_platform_admin() and status <> 'declined' order by status = 'pending' desc, name $$;

-- ---------- grants ----------
revoke execute on function private.is_owner(), private.is_account_manager(uuid), private.is_any_account_manager() from public, anon;
grant execute on function private.is_owner(), private.is_account_manager(uuid), private.is_any_account_manager() to authenticated;
revoke execute on function public.my_is_owner(), public.church_account_managers(), public.am_overview(), public.admin_roles(), public.admin_add_role(text, text),
  public.admin_remove_role(uuid, text), public.admin_set_am_churches(uuid, uuid[]), public.admin_all_churches() from public, anon;
grant execute on function public.my_is_owner(), public.church_account_managers(), public.am_overview(), public.admin_roles(), public.admin_add_role(text, text),
  public.admin_remove_role(uuid, text), public.admin_set_am_churches(uuid, uuid[]), public.admin_all_churches() to authenticated;
