-- 0004: platform admin assigns and removes church admins by email.
-- A church admin can open the Leader Console for that church, approve members and name group leaders.

-- List active church admins (platform admin only)
create or replace function public.admin_church_admins()
returns table (church_id uuid, user_id uuid, email text, name text, since timestamptz)
language sql stable security definer set search_path = public, private as $$
  select r.church_id, r.user_id, u.email::text,
         nullif(trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), ''), r.verified_at
  from role_assignments r
  join auth.users u on u.id = r.user_id
  left join partners p on p.auth_user_id = r.user_id
  where private.is_platform_admin() and r.role = 'church_admin' and r.church_id is not null
    and r.verified_at is not null and r.revoked_at is null
  order by r.verified_at $$;

-- Add or remove a church admin by the email of an existing account
create or replace function public.admin_set_church_admin(p_church uuid, p_email text, p_on boolean)
returns text language plpgsql security definer set search_path = public, private as $$
declare uid_ uuid; ch churches;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can assign church admins.'; end if;
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

revoke execute on function public.admin_church_admins() from public, anon;
revoke execute on function public.admin_set_church_admin(uuid, text, boolean) from public, anon;
grant execute on function public.admin_church_admins() to authenticated;
grant execute on function public.admin_set_church_admin(uuid, text, boolean) to authenticated;
