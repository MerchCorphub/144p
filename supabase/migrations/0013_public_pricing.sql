-- 0013: current prices for sign-up and the "Get the study book" page (readable before sign-in),
-- always read live from license_plans so Admin Panel › Prices changes show everywhere,
-- and a summary of what the signed-in member has (church coverage, own seat, end date).
create or replace function public.public_pricing() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'individual', (select price from license_plans where kind = 'individual' and active order by sort_order limit 1),
    'church_from', (select min(price) from license_plans where kind = 'church' and active),
    'church_plans', (select coalesce(json_agg(json_build_object('name', name, 'seats', seat_limit, 'price', price) order by sort_order), '[]'::json) from license_plans where kind = 'church' and active)) $$;
revoke execute on function public.public_pricing() from public;
grant execute on function public.public_pricing() to anon, authenticated;

create or replace function public.my_access() returns json
language plpgsql stable security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); m record; seat record;
begin
  select ms.status, c.name, (private.current_church_license(ms.church_id)).status as lic into m
  from memberships ms join churches c on c.id = ms.church_id where ms.partner_id = pid and ms.status in ('pending', 'verified') limit 1;
  select i.expires_at, i.price into seat from individual_seats i, seasons s
  where s.active and i.partner_id = pid and i.status = 'active' and private.license_covers(i.season_id, i.expires_at, s)
  order by i.expires_at desc nulls last limit 1;
  return json_build_object('church', m.name, 'church_status', m.status, 'church_license', m.lic,
    'church_covers', m.status = 'verified' and m.lic = 'active',
    'seat', seat.expires_at is not null or seat.price is not null, 'seat_expires', seat.expires_at,
    'admin', private.is_platform_admin());
end $$;
revoke execute on function public.my_access() from public, anon;
grant execute on function public.my_access() to authenticated;
