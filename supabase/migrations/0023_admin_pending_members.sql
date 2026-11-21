-- 0023: every request to join a church, across all churches, for the Admin Panel › No church tab.
-- Approving and declining use the existing approve_memberships / decline_memberships (admins pass
-- their can_approve check for every church; seat limits still apply).
create or replace function public.admin_pending_members()
returns table (membership_id uuid, partner_id uuid, name text, email text, church_id uuid, church text, requested_at timestamptz,
               seats int, used bigint, own_seat boolean)
language sql stable security definer set search_path = public, private as $$
  select m.id, p.id, trim(p.first_name || ' ' || p.last_name), p.email, c.id, c.name, m.joined_at,
    (private.current_church_license(c.id)).seats,
    (select count(*) from memberships v where v.church_id = c.id and v.status = 'verified'),
    private.has_individual_seat(p.id)
  from memberships m join partners p on p.id = m.partner_id join churches c on c.id = m.church_id
  where private.is_platform_admin() and m.status = 'pending'
  order by m.joined_at $$;
revoke execute on function public.admin_pending_members() from public, anon;
grant execute on function public.admin_pending_members() to authenticated;
