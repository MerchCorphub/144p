-- 0012: leaders see when two people in their church share a first and last name, so they can check
-- the email; the Leader Console asks a leader with an unfinished name to complete it.
drop function if exists public.leader_members(uuid);
create function public.leader_members(cid uuid)
returns table (membership_id uuid, name text, email text, status text, joined_at date, is_leader boolean, same_name int)
language sql stable security definer set search_path = public, private as $$
  select m.id, p.first_name || ' ' || p.last_name, p.email, m.status, m.joined_at,
    exists (select 1 from role_assignments r where r.user_id = p.auth_user_id and r.church_id = cid and r.role = 'table_leader' and r.verified_at is not null and r.revoked_at is null),
    (select count(*)::int from memberships m2 join partners p2 on p2.id = m2.partner_id
      where m2.church_id = cid and m2.id <> m.id and m2.status in ('pending', 'verified')
        and lower(trim(p2.first_name)) = lower(trim(p.first_name)) and lower(trim(p2.last_name)) = lower(trim(p.last_name)))
  from memberships m join partners p on p.id = m.partner_id
  where m.church_id = cid and m.status in ('pending', 'verified') and private.can_approve(cid)
  order by m.status desc, p.last_name, p.first_name $$;
revoke execute on function public.leader_members(uuid) from public, anon;
grant execute on function public.leader_members(uuid) to authenticated;

create or replace function public.my_profile_complete() returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select first_name <> 'Partner' and trim(first_name) <> '' and trim(last_name) <> '' from partners where id = private.my_partner_id()), true) $$;
revoke execute on function public.my_profile_complete() from public, anon;
grant execute on function public.my_profile_complete() to authenticated;
