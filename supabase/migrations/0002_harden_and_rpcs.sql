-- 144(P) Plan — applied to project nkmdddossplaaswsqnxb on 2026-11-07
-- 1) Security hardening after Supabase advisors  2) App RPCs  3) Nightly aggregate job

-- ---------- helpers out of the exposed API ----------
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated;
alter function public.my_partner_id() set schema private;
alter function public.is_platform_admin() set schema private;
alter function public.is_church_admin(uuid) set schema private;
revoke execute on all functions in schema private from public;
grant execute on all functions in schema private to anon, authenticated;
alter function public.redeem_time(text,text,int,text,uuid) set search_path = public, private;
alter function public.church_participation(uuid) set search_path = public, private;
revoke execute on function public.redeem_time(text,text,int,text,uuid) from public, anon;
revoke execute on function public.church_participation(uuid) from public, anon;
grant execute on function public.redeem_time(text,text,int,text,uuid) to authenticated;
grant execute on function public.church_participation(uuid) to authenticated;

-- account_start_date is server-owned (blocks backdating past the commissioning gate)
create or replace function private.lock_start_date() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.account_start_date := current_date;
  else new.account_start_date := old.account_start_date; new.auth_user_id := old.auth_user_id; end if;
  return new;
end $$;
create trigger partners_lock_start before insert or update on partners for each row execute function private.lock_start_date();

-- ---------- policies: per-statement auth.uid(), one permissive policy per action ----------
drop policy own_partner on partners;
create policy own_partner on partners for all to authenticated using (auth_user_id = (select auth.uid())) with check (auth_user_id = (select auth.uid()));
drop policy roles_read_own on role_assignments;
create policy roles_read_own on role_assignments for select to authenticated using (user_id = (select auth.uid()) or (select private.is_platform_admin()));

drop policy church_read on churches; drop policy church_admin_update on churches; drop policy platform_church_all on churches;
create policy churches_select on churches for select to authenticated using (private.is_platform_admin() or private.is_church_admin(id) or exists(select 1 from memberships m where m.church_id = churches.id and m.partner_id = private.my_partner_id() and m.status <> 'removed'));
create policy churches_update on churches for update to authenticated using (private.is_platform_admin() or private.is_church_admin(id)) with check (private.is_platform_admin() or private.is_church_admin(id));
create policy churches_insert on churches for insert to authenticated with check (private.is_platform_admin());
create policy churches_delete on churches for delete to authenticated using (private.is_platform_admin());

drop policy own_membership on memberships; drop policy request_membership on memberships; drop policy church_admin_memberships on memberships;
create policy memberships_select on memberships for select to authenticated using (partner_id = private.my_partner_id() or private.is_church_admin(church_id));
create policy memberships_insert on memberships for insert to authenticated with check ((partner_id = private.my_partner_id() and status = 'pending') or private.is_church_admin(church_id));
create policy memberships_update on memberships for update to authenticated using (private.is_church_admin(church_id)) with check (private.is_church_admin(church_id));
create policy memberships_delete on memberships for delete to authenticated using (private.is_church_admin(church_id));

drop policy own_sharing on sharing_permissions; drop policy shared_with_me on sharing_permissions;
create policy sharing_select on sharing_permissions for select to authenticated using (owner_partner_id = private.my_partner_id() or (recipient_partner_id = private.my_partner_id() and enabled and revoked_at is null));
create policy sharing_insert on sharing_permissions for insert to authenticated with check (owner_partner_id = private.my_partner_id());
create policy sharing_update on sharing_permissions for update to authenticated using (owner_partner_id = private.my_partner_id()) with check (owner_partner_id = private.my_partner_id());
create policy sharing_delete on sharing_permissions for delete to authenticated using (owner_partner_id = private.my_partner_id());

drop policy plans_admin on subscription_plans;
create policy plans_insert on subscription_plans for insert to authenticated with check (private.is_platform_admin());
create policy plans_update on subscription_plans for update to authenticated using (private.is_platform_admin()) with check (private.is_platform_admin());
create policy plans_delete on subscription_plans for delete to authenticated using (private.is_platform_admin());

drop policy tables_read on tables; drop policy tables_admin on tables;
create policy tables_select on tables for select to authenticated using (private.is_platform_admin() or private.is_church_admin(church_id) or exists(select 1 from memberships m where m.church_id = tables.church_id and m.partner_id = private.my_partner_id() and m.status <> 'removed'));
create policy tables_insert on tables for insert to authenticated with check (private.is_church_admin(church_id));
create policy tables_update on tables for update to authenticated using (private.is_church_admin(church_id)) with check (private.is_church_admin(church_id));
create policy tables_delete on tables for delete to authenticated using (private.is_church_admin(church_id));

create policy subs_platform_write on church_subscriptions for insert to authenticated with check (private.is_platform_admin());
create policy subs_platform_update on church_subscriptions for update to authenticated using (private.is_platform_admin()) with check (private.is_platform_admin());

-- ---------- foreign-key indexes ----------
create index on church_invitations(church_id);
create index on church_subscriptions(plan_id);
create index on deposit_notes(partner_id);
create index on memberships(table_id);
create index on redemption_catalog(church_id);
create index on role_assignments(church_id);
create index on role_assignments(user_id);
create index on sharing_permissions(owner_partner_id);
create index on sharing_permissions(recipient_partner_id);
create index on subscription_events(church_id);
create index on subscription_events(subscription_id);
create index on tables(church_id);
create index on time_redemptions(catalog_id);

-- ---------- app RPCs ----------
create or replace function public.church_by_slug(p_slug text)
returns table(id uuid, name text, enrollment_policy text) language sql stable security definer set search_path = public as $$
  select id, name, enrollment_policy from churches where slug = p_slug $$;

create or replace function public.invitation_preview(p_token text)
returns table(church_name text, invited_email text, invited_name text, invited_title text, expires_at timestamptz, accepted boolean)
language sql stable security definer set search_path = public, extensions as $$
  select c.name, i.invited_email, i.invited_name, i.invited_title, i.expires_at, i.accepted_at is not null
  from church_invitations i join churches c on c.id = i.church_id
  where i.invitation_token_hash = encode(digest(p_token, 'sha256'), 'hex') $$;

create or replace function public.join_church(p_slug text)
returns text language plpgsql security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); ch churches; st text;
begin
  if pid is null then raise exception 'not a partner'; end if;
  select * into ch from churches where slug = p_slug; if ch.id is null then raise exception 'church not found'; end if;
  select status into st from memberships where partner_id = pid and church_id = ch.id and status <> 'removed';
  if st is not null then return st; end if;
  update memberships set status = 'removed', table_id = null where partner_id = pid and status <> 'removed';
  st := case when ch.enrollment_policy = 'open' then 'verified' else 'pending' end;
  insert into memberships(partner_id, church_id, status, last_active_at) values (pid, ch.id, st, current_date);
  insert into audit_logs(actor_id, organization_id, action, resource_type) values (auth.uid(), ch.id, 'membership.requested', 'membership');
  return st;
end $$;

create or replace function public.touch_activity() returns void language sql security definer set search_path = public, private as $$
  update memberships set last_active_at = current_date where partner_id = private.my_partner_id() and status <> 'removed' and last_active_at is distinct from current_date $$;

create or replace function public.church_members(cid uuid)
returns table(id uuid, partner_id uuid, name text, email text, table_id uuid, status text, joined_at date, last_active_at date)
language sql stable security definer set search_path = public, private as $$
  select m.id, m.partner_id, p.first_name || ' ' || p.last_name, p.email, m.table_id, m.status, m.joined_at, m.last_active_at
  from memberships m join partners p on p.id = m.partner_id
  where m.church_id = cid and (private.is_church_admin(cid) or private.is_platform_admin()) $$;

create or replace function public.my_admin_roles()
returns table(role app_role, church_id uuid) language sql stable security definer set search_path = public as $$
  select role, church_id from role_assignments where user_id = auth.uid() and verified_at is not null and revoked_at is null $$;

create or replace function public.church_admins()
returns table(user_id uuid, church_id uuid, name text, email text, title text, verified_at timestamptz, revoked_at timestamptz)
language sql stable security definer set search_path = public, private as $$
  select r.user_id, r.church_id, coalesce(u.raw_user_meta_data->>'name', u.email), u.email, u.raw_user_meta_data->>'title', r.verified_at, r.revoked_at
  from role_assignments r join auth.users u on u.id = r.user_id
  where r.role = 'church_admin' and (private.is_platform_admin() or private.is_church_admin(r.church_id)) $$;

create or replace function public.accept_invitation(p_token text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare inv church_invitations; em text;
begin
  select * into inv from church_invitations where invitation_token_hash = encode(digest(p_token, 'sha256'), 'hex');
  if inv.id is null or inv.accepted_at is not null or inv.expires_at < now() then raise exception 'invitation is no longer valid'; end if;
  select email into em from auth.users where id = auth.uid();
  if lower(em) <> lower(inv.invited_email) then raise exception 'sign in with the invited email address'; end if;
  update church_invitations set accepted_at = now() where id = inv.id;
  insert into role_assignments(user_id, church_id, role, verified_at) values (auth.uid(), inv.church_id, 'church_admin', now());
  insert into audit_logs(actor_id, organization_id, action, resource_type, resource_id) values (auth.uid(), inv.church_id, 'admin.invitation_accepted', 'church_invitation', inv.id::text);
  return inv.church_id;
end $$;

create or replace function public.delete_my_account() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into audit_logs(action, resource_type) values ('account.deleted', 'partner');
  delete from auth.users where id = auth.uid();
end $$;

revoke execute on function public.church_by_slug(text) from public;
revoke execute on function public.invitation_preview(text) from public;
grant execute on function public.church_by_slug(text) to anon, authenticated;
grant execute on function public.invitation_preview(text) to anon, authenticated;
do $$ declare f text; begin
  foreach f in array array['join_church(text)','touch_activity()','church_members(uuid)','my_admin_roles()','church_admins()','accept_invitation(text)','delete_my_account()']
  loop execute format('revoke execute on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;

-- ---------- nightly aggregate (counts only) ----------
create or replace function private.refresh_participation() returns void language sql security definer set search_path = public as $$
  insert into participation_weekly(church_id, week_start, participants, minutes)
  select m.church_id, date_trunc('week', d.activity_date)::date, count(distinct d.partner_id), sum(d.minutes)
  from time_deposits d join memberships m on m.partner_id = d.partner_id and m.status = 'verified'
  where d.voided_at is null and d.activity_date >= current_date - 84
  group by 1, 2
  on conflict (church_id, week_start) do update set participants = excluded.participants, minutes = excluded.minutes $$;
revoke execute on function private.refresh_participation() from anon, authenticated, public;
create extension if not exists pg_cron;
select cron.schedule('refresh-participation', '15 3 * * *', 'select private.refresh_participation()');
