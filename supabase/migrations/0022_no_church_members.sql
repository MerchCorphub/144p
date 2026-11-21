-- 0022: Admin Panel › No church. Members whose account isn't in any church (no pending or
-- approved membership), with what they have and how active they are, and a way to add them
-- to a church as an approved member.
create or replace function public.admin_no_church()
returns table (partner_id uuid, name text, email text, created_at timestamptz, last_active date, minutes_all bigint, minutes_30 bigint,
               own_seat boolean, guest_until date, book_key boolean, past_church text, past_status text)
language sql stable security definer set search_path = public, private as $$
  select p.id, trim(p.first_name || ' ' || p.last_name), p.email, p.created_at,
    (select max(d.activity_date) from time_deposits d where d.partner_id = p.id and d.voided_at is null),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d where d.partner_id = p.id and d.voided_at is null),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d where d.partner_id = p.id and d.voided_at is null and d.activity_date > current_date - 30),
    private.has_individual_seat(p.id), private.guest_until(p.id),
    exists (select 1 from key_claims k where k.partner_id = p.id),
    (select c.name from memberships m join churches c on c.id = m.church_id where m.partner_id = p.id order by m.joined_at desc limit 1),
    (select m.status from memberships m where m.partner_id = p.id order by m.joined_at desc limit 1)
  from partners p
  where private.is_platform_admin()
    and not exists (select 1 from memberships m where m.partner_id = p.id and m.status in ('pending', 'verified'))
  order by p.created_at desc $$;

create or replace function public.admin_add_to_church(p_partner uuid, p_church uuid, p_notify boolean default true) returns text
language plpgsql security definer set search_path = public, private as $$
declare p partners; c churches;
begin
  if not private.is_platform_admin() then raise exception 'Only an admin can add members to a church.'; end if;
  select * into p from partners where id = p_partner;
  select * into c from churches where id = p_church;
  if p.id is null then raise exception 'That member was not found.'; end if;
  if c.id is null or c.status <> 'active' then raise exception 'Choose an approved church.'; end if;
  if exists (select 1 from memberships where partner_id = p.id and status in ('pending', 'verified')) then
    raise exception '% is already in a church.', p.first_name;
  end if;
  insert into memberships (partner_id, church_id, status, last_active_at) values (p.id, c.id, 'verified', current_date);
  insert into audit_logs (actor_id, organization_id, action, resource_type, resource_id) values (auth.uid(), c.id, 'membership.added_by_admin', 'partner', p.id::text);
  if p_notify then
    perform private.queue_email(p.email, 'You’re now part of ' || c.name || ' in the 144(P) Plan',
      array['Hi ' || h(p.first_name) || ', you’ve been added to <strong>' || h(c.name) || '</strong> in the 144(P) Plan app.',
            'Your church’s leaders can now place you in a group, and your time with God counts toward your church in the Time4God Challenge.'],
      'Open the app', 'https://time4god.app/', null, 'member.added_to_church');
  end if;
  return 'added';
end $$;

revoke execute on function public.admin_no_church(), public.admin_add_to_church(uuid, uuid, boolean) from public, anon;
grant execute on function public.admin_no_church(), public.admin_add_to_church(uuid, uuid, boolean) to authenticated;
