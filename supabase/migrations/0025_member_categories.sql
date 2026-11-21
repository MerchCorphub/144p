-- 0025: three member categories.
--  Member   paid: bought the study book (incl. keep going), approved in a church with active seats,
--           claimed a printed-book key, or leads a licensed church.
--  Guest    a temporary seat from a Member's Time4God Challenge, while it lasts.
--  Prospect a free account that hasn't paid (incl. guests whose challenge has ended).
create or replace function private.member_category(pid uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select case when private.paid_access(pid) then 'member'
              when coalesce(private.guest_until(pid) >= current_date, false) then 'guest'
              else 'prospect' end $$;

-- How a Member is covered (the first that applies)
create or replace function private.member_paid_by(pid uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select case
    when exists (select 1 from payments p where p.buyer_partner_id = pid and p.kind = 'individual' and p.status = 'paid') and private.has_individual_seat(pid) then 'bought'
    when exists (select 1 from key_claims k where k.partner_id = pid) and private.has_individual_seat(pid) then 'book_key'
    when private.has_individual_seat(pid) then 'own_seat'
    when exists (select 1 from memberships m where m.partner_id = pid and m.status = 'verified' and (private.current_church_license(m.church_id)).status = 'active') then 'church'
    when private.paid_access(pid) then 'leader' end $$;

create or replace function public.my_access() returns json
language plpgsql stable security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); m record; seat record; g record; gu date;
begin
  select ms.status, c.name, (private.current_church_license(ms.church_id)).status as lic into m
  from memberships ms join churches c on c.id = ms.church_id where ms.partner_id = pid and ms.status in ('pending', 'verified') limit 1;
  select i.expires_at, i.price into seat from individual_seats i, seasons s
  where s.active and i.partner_id = pid and i.status = 'active' and private.license_covers(i.season_id, i.expires_at, s)
  order by i.expires_at desc nulls last limit 1;
  gu := private.guest_until(pid);
  select (select first_name from partners where id = gp.owner_partner_id) as giver into g
  from guest_passes gp where gp.claimed_by = pid order by gp.access_until desc limit 1;
  return json_build_object('church', m.name, 'church_status', m.status, 'church_license', m.lic,
    'church_covers', m.status = 'verified' and m.lic = 'active',
    'seat', seat.expires_at is not null or seat.price is not null, 'seat_expires', seat.expires_at,
    'guest_until', gu, 'guest_active', coalesce(gu >= current_date, false), 'guest_from', g.giver,
    'keep_going_price', private.keep_going_price(pid),
    'guest_seats_left', private.guest_seats_left(pid),
    'guest_seat_given_to', (select p.first_name from guest_passes gp join partners p on p.id = gp.claimed_by
                            where gp.owner_partner_id = pid order by gp.claimed_at desc limit 1),
    'category', case when pid is null then null else private.member_category(pid) end,
    'paid_by', case when pid is null then null else private.member_paid_by(pid) end,
    'admin', private.is_platform_admin());
end $$;

-- Admin Panel › All members
create or replace function public.admin_all_members()
returns table (partner_id uuid, name text, email text, created_at timestamptz, category text, paid_by text, guest_until date, guest_from text,
               church text, church_status text, minutes_all bigint, minutes_30 bigint, last_active date)
language sql stable security definer set search_path = public, private as $$
  select p.id, trim(p.first_name || ' ' || p.last_name), p.email, p.created_at,
    private.member_category(p.id), private.member_paid_by(p.id), private.guest_until(p.id),
    (select o.first_name from guest_passes gp join partners o on o.id = gp.owner_partner_id where gp.claimed_by = p.id order by gp.access_until desc limit 1),
    (select c.name from memberships m join churches c on c.id = m.church_id where m.partner_id = p.id and m.status in ('pending', 'verified') limit 1),
    (select m.status from memberships m where m.partner_id = p.id and m.status in ('pending', 'verified') limit 1),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d where d.partner_id = p.id and d.voided_at is null),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d where d.partner_id = p.id and d.voided_at is null and d.activity_date > current_date - 30),
    (select max(d.activity_date) from time_deposits d where d.partner_id = p.id and d.voided_at is null)
  from partners p where private.is_platform_admin() order by p.created_at desc $$;

-- No church tab: add the category
drop function if exists public.admin_no_church();
create function public.admin_no_church()
returns table (partner_id uuid, name text, email text, created_at timestamptz, last_active date, minutes_all bigint, minutes_30 bigint,
               own_seat boolean, guest_until date, book_key boolean, past_church text, past_status text, category text)
language sql stable security definer set search_path = public, private as $$
  select p.id, trim(p.first_name || ' ' || p.last_name), p.email, p.created_at,
    (select max(d.activity_date) from time_deposits d where d.partner_id = p.id and d.voided_at is null),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d where d.partner_id = p.id and d.voided_at is null),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d where d.partner_id = p.id and d.voided_at is null and d.activity_date > current_date - 30),
    private.has_individual_seat(p.id), private.guest_until(p.id),
    exists (select 1 from key_claims k where k.partner_id = p.id),
    (select c.name from memberships m join churches c on c.id = m.church_id where m.partner_id = p.id order by m.joined_at desc limit 1),
    (select m.status from memberships m where m.partner_id = p.id order by m.joined_at desc limit 1),
    private.member_category(p.id)
  from partners p
  where private.is_platform_admin()
    and not exists (select 1 from memberships m where m.partner_id = p.id and m.status in ('pending', 'verified'))
  order by p.created_at desc $$;

-- Dashboard: category counts
create or replace function public.admin_dashboard() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  return (private.admin_dashboard_base()::jsonb || jsonb_build_object(
    'guests', jsonb_build_object(
      'given', (select count(*) from guest_passes),
      'used', (select count(*) from guest_passes where claimed_by is not null),
      'active', (select count(*) from guest_passes where access_until >= current_date),
      'kept_going', (select count(*) from guest_passes gp where gp.claimed_by is not null
                       and exists (select 1 from payments p where p.buyer_partner_id = gp.claimed_by and p.status = 'paid' and p.kind = 'individual'))),
    'invoices', jsonb_build_object(
      'open', (select count(*) from payments where method = 'invoice' and status = 'open' and stripe_invoice_id is not null and not coalesce(test, false)),
      'open_amount', (select coalesce(sum(amount), 0) from payments where method = 'invoice' and status = 'open' and stripe_invoice_id is not null and not coalesce(test, false)),
      'overdue', (select count(*) from payments where method = 'invoice' and status = 'open' and stripe_invoice_id is not null and due_date < current_date and not coalesce(test, false))),
    'categories', (select jsonb_build_object(
      'member', count(*) filter (where c = 'member'), 'guest', count(*) filter (where c = 'guest'), 'prospect', count(*) filter (where c = 'prospect'))
      from (select private.member_category(id) c from partners) x)
  ))::json;
end $$;

revoke execute on function private.member_category(uuid), private.member_paid_by(uuid) from public, anon;
grant execute on function private.member_category(uuid), private.member_paid_by(uuid) to authenticated;
revoke execute on function public.admin_all_members(), public.admin_no_church(), public.admin_dashboard(), public.my_access() from public, anon;
grant execute on function public.admin_all_members(), public.admin_no_church(), public.admin_dashboard(), public.my_access() to authenticated;
