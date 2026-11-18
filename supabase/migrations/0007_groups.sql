-- 0007: groups inside a church. Church admins create, rename and delete groups and choose
-- each group's leader. Church admins can move any approved member in or out of any group;
-- a group leader can add unassigned members to their own group and remove members from it.

create or replace function private.manages_church(cid uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce(private.is_platform_admin() or private.is_church_admin(cid), false) $$;

-- A group leader now speaks for the group they were made leader of; fall back to the old rule
create or replace function private.my_led_table()
returns uuid language sql stable security definer set search_path = public, private as $$
  select coalesce(
    (select t.id from tables t join memberships m on m.church_id = t.church_id and m.partner_id = t.leader_partner_id and m.status = 'verified'
      where t.leader_partner_id = private.my_partner_id() and t.status = 'active' order by t.created_at limit 1),
    (select m.table_id from memberships m
      where m.partner_id = private.my_partner_id() and m.status = 'verified' and m.table_id is not null
        and (private.is_church_admin(m.church_id) or exists (select 1 from role_assignments r where r.user_id = auth.uid() and r.church_id = m.church_id and r.role = 'table_leader' and r.verified_at is not null and r.revoked_at is null))
      limit 1)) $$;

create or replace function public.church_groups(cid uuid)
returns table (group_id uuid, name text, leader_partner_id uuid, leader_name text, members int, i_lead boolean, can_edit boolean)
language sql stable security definer set search_path = public, private as $$
  select t.id, t.name, t.leader_partner_id,
    (select p.first_name || ' ' || p.last_name from partners p where p.id = t.leader_partner_id),
    (select count(*)::int from memberships m where m.table_id = t.id and m.status = 'verified'),
    coalesce(t.leader_partner_id = private.my_partner_id(), false),
    private.manages_church(cid) or coalesce(t.leader_partner_id = private.my_partner_id(), false)
  from tables t where t.church_id = cid and t.status = 'active' and private.can_approve(cid)
  order by t.name $$;

create or replace function public.group_roster(cid uuid)
returns table (membership_id uuid, partner_id uuid, name text, email text, group_id uuid)
language sql stable security definer set search_path = public, private as $$
  select m.id, p.id, p.first_name || ' ' || p.last_name, p.email, m.table_id
  from memberships m join partners p on p.id = m.partner_id
  where m.church_id = cid and m.status = 'verified' and private.can_approve(cid)
  order by p.last_name, p.first_name $$;

create or replace function public.save_group(cid uuid, p_id uuid, p_name text)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare nm text := nullif(trim(p_name), ''); gid uuid;
begin
  if not private.manages_church(cid) then raise exception 'Only the church admin can create or rename groups.'; end if;
  if nm is null then raise exception 'Enter a group name.'; end if;
  if char_length(nm) > 60 then raise exception 'Keep the group name under 60 characters.'; end if;
  if exists (select 1 from tables where church_id = cid and status = 'active' and lower(name) = lower(nm) and id is distinct from p_id) then
    raise exception 'This church already has a group named %.', nm;
  end if;
  if p_id is null then
    insert into tables (church_id, name) values (cid, nm) returning id into gid;
  else
    update tables set name = nm where id = p_id and church_id = cid returning id into gid;
    if gid is null then raise exception 'That group was not found.'; end if;
  end if;
  return gid;
end $$;

create or replace function public.delete_group(p_id uuid)
returns void language plpgsql security definer set search_path = public, private as $$
declare t tables;
begin
  select * into t from tables where id = p_id;
  if t.id is null then raise exception 'That group was not found.'; end if;
  if not private.manages_church(t.church_id) then raise exception 'Only the church admin can delete groups.'; end if;
  if exists (select 1 from challenges where (a_table = p_id or b_table = p_id) and status in ('pending', 'active') and end_date >= current_date) then
    raise exception 'This group is in a challenge that hasn''t finished. Delete it after the challenge ends.';
  end if;
  update memberships set table_id = null where table_id = p_id;
  delete from tables where id = p_id;
end $$;

-- Choose (or clear) a group's leader. The leader is placed in the group and can approve members.
create or replace function public.set_group_lead(p_group uuid, p_partner uuid)
returns void language plpgsql security definer set search_path = public, private as $$
declare t tables; uid_ uuid;
begin
  select * into t from tables where id = p_group;
  if t.id is null then raise exception 'That group was not found.'; end if;
  if not private.manages_church(t.church_id) then raise exception 'Only the church admin can choose group leaders.'; end if;
  if p_partner is null then update tables set leader_partner_id = null where id = p_group; return; end if;
  if not exists (select 1 from memberships where partner_id = p_partner and church_id = t.church_id and status = 'verified') then
    raise exception 'The group leader must be an approved member of this church.';
  end if;
  update tables set leader_partner_id = p_partner where id = p_group;
  update memberships set table_id = p_group where partner_id = p_partner and church_id = t.church_id and status = 'verified';
  select auth_user_id into uid_ from partners where id = p_partner;
  if not exists (select 1 from role_assignments where user_id = uid_ and church_id = t.church_id and role = 'table_leader' and revoked_at is null) then
    insert into role_assignments (user_id, church_id, role, verified_at) values (uid_, t.church_id, 'table_leader', now());
  end if;
  insert into audit_logs (actor_id, organization_id, action, resource_type, resource_id) values (auth.uid(), t.church_id, 'group.leader_set', 'group', p_group::text);
end $$;

-- Put members in a group (p_group) or take them out (p_group null). All or nothing.
create or replace function public.set_members_group(p_ids uuid[], p_group uuid)
returns int language plpgsql security definer set search_path = public, private as $$
declare t tables; cid uuid; boss boolean; mine uuid := private.my_partner_id(); bad int; n int;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  select min(church_id::text)::uuid into cid from memberships where id = any(p_ids);
  if cid is null or (select count(distinct church_id) from memberships where id = any(p_ids)) > 1 then raise exception 'Those members were not found.'; end if;
  if (select count(*) from memberships where id = any(p_ids) and status = 'verified') <> array_length(p_ids, 1) then raise exception 'Only approved members can be placed in groups.'; end if;
  boss := private.manages_church(cid);
  if p_group is not null then
    select * into t from tables where id = p_group and status = 'active';
    if t.id is null or t.church_id <> cid then raise exception 'That group was not found in this church.'; end if;
  end if;
  if not boss then
    if p_group is not null then
      if t.leader_partner_id is distinct from mine then raise exception 'You can only add members to the group you lead.'; end if;
      select count(*) into bad from memberships where id = any(p_ids) and table_id is not null and table_id <> p_group;
      if bad > 0 then raise exception 'Some of those members are already in another group. Ask your church admin to move them.'; end if;
    else
      select count(*) into bad from memberships m left join tables tb on tb.id = m.table_id
        where m.id = any(p_ids) and (tb.id is null or tb.leader_partner_id is distinct from mine);
      if bad > 0 then raise exception 'You can only remove members from the group you lead.'; end if;
      if exists (select 1 from memberships where id = any(p_ids) and partner_id = mine) then raise exception 'Ask your church admin to remove you from your own group.'; end if;
    end if;
  end if;
  update memberships set table_id = p_group where id = any(p_ids);
  get diagnostics n = row_count;
  -- a leader moved out of their group stops leading it
  update tables set leader_partner_id = null
    where church_id = cid and id is distinct from p_group and leader_partner_id in (select partner_id from memberships where id = any(p_ids));
  return n;
end $$;

do $$ declare f text; begin
  foreach f in array array['church_groups(uuid)', 'group_roster(uuid)', 'save_group(uuid, uuid, text)', 'delete_group(uuid)',
    'set_group_lead(uuid, uuid)', 'set_members_group(uuid[], uuid)']
  loop execute format('revoke execute on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
revoke execute on function private.manages_church(uuid) from public, anon;
grant execute on function private.manages_church(uuid) to authenticated;
