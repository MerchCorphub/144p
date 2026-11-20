-- 0017: churches and groups buy any number of seats, priced per seat.
-- The church rows in license_plans become volume tiers: min_seats..seat_limit, and price is
-- the price PER SEAT for a total in that range. Smallest purchase is 5 seats.
--   Small group  5–999        $18 a seat
--   Ministry     1,000–4,999  $15 a seat
--   Church       5,000–19,999 $10 a seat
--   Church-wide  20,000+      $8 a seat (up to 100,000)
-- Adding seats later: the added seats are priced at the rate for the new total and end on
-- the same date as the church's other seats. Individual price is unchanged.

alter table public.license_plans add column if not exists min_seats int not null default 1 check (min_seats >= 1);
alter table public.payments add column if not exists seats int;

update public.license_plans set min_seats = 5,     seat_limit = 999,    price = 18 where kind = 'church' and name = 'Small group';
update public.license_plans set min_seats = 1000,  seat_limit = 4999,   price = 15 where kind = 'church' and name = 'Ministry';
update public.license_plans set min_seats = 5000,  seat_limit = 19999,  price = 10 where kind = 'church' and name = 'Church';
update public.license_plans set min_seats = 20000, seat_limit = 100000, price = 8  where kind = 'church' and name = 'Church-wide';

-- The tier (and per-seat price) for a church with n seats in total
create or replace function private.church_tier(n int) returns public.license_plans
language sql stable security definer set search_path = public as $$
  select * from license_plans where kind = 'church' and active and n between min_seats and seat_limit
  order by sort_order limit 1 $$;

create or replace function public.public_pricing() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'individual', (select price from license_plans where kind = 'individual' and active order by sort_order limit 1),
    'church_from', (select min(price) from license_plans where kind = 'church' and active),
    'church_top_rate', (select price from license_plans where kind = 'church' and active order by min_seats limit 1),
    'church_min_seats', (select min(min_seats) from license_plans where kind = 'church' and active),
    'per_seat', true,
    'church_plans', (select coalesce(json_agg(json_build_object('name', name, 'min', min_seats, 'seats', seat_limit, 'price', price) order by min_seats), '[]'::json)
                     from license_plans where kind = 'church' and active)) $$;

create or replace function public.purchase_options(cid uuid default null)
returns json language plpgsql stable security definer set search_path = public, private as $$
declare l church_licenses; ind license_plans; me uuid := private.my_partner_id();
begin
  select * into ind from license_plans where kind = 'individual' and active order by sort_order limit 1;
  if cid is null then
    return json_build_object('individual_price', ind.price, 'has_seat', private.has_individual_seat(me),
      'keep_going_price', private.keep_going_price(me), 'discount', private.keep_going_discount());
  end if;
  if not private.manages_church(cid) then raise exception 'Only the church admin can buy seats for this church.'; end if;
  l := private.current_church_license(cid);
  return json_build_object(
    'current', case when l.id is not null then json_build_object('seats', l.seats, 'price', l.price, 'status', l.status, 'expires_at', l.expires_at,
                     'plan', (select name from license_plans where id = l.plan_id)) end,
    'used', (select count(*) from memberships where church_id = cid and status = 'verified'),
    'min_seats', (select min(min_seats) from license_plans where kind = 'church' and active),
    'max_seats', (select max(seat_limit) from license_plans where kind = 'church' and active),
    'tiers', (select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'min', p.min_seats, 'max', p.seat_limit, 'rate', p.price) order by p.min_seats), '[]'::json)
              from license_plans p where p.kind = 'church' and p.active));
end $$;

drop function if exists public.stripe_prepare(uuid, text, uuid, uuid);
create function public.stripe_prepare(p_user uuid, p_type text, p_church uuid, p_plan uuid, p_seats int default null)
returns json language plpgsql security definer set search_path = public, private as $$
declare pid uuid; em text; s seasons; p license_plans; l church_licenses; amt numeric; k text; d text; pay uuid; ch churches; boss boolean;
        disc numeric := 0; total int; lo int; hi int; rate text;
begin
  select id, email into pid, em from partners where auth_user_id = p_user;
  if pid is null then raise exception 'Create your account first.'; end if;
  select * into s from seasons where active limit 1;
  if s.id is null then raise exception 'No season is open yet.'; end if;
  if p_type in ('individual', 'keep_going') then
    select * into p from license_plans where kind = 'individual' and active order by sort_order limit 1;
    if p.id is null then raise exception 'Individual seats are not available right now.'; end if;
    if private.has_individual_seat(pid) then raise exception 'You already have the book in the app.'; end if;
    k := 'individual';
    if p_type = 'keep_going' then
      amt := private.keep_going_price(pid);
      if amt is null then raise exception 'The keep-going price is for guests of a Time4God Challenge.'; end if;
      disc := p.price - amt;
      d := 'Time4God Challenge · keep going, book in the app (1 year)';
    else
      amt := p.price; d := 'Time4God Challenge · book in the app (1 year)';
    end if;
  elsif p_type = 'church' then
    select * into ch from churches where id = p_church;
    if ch.id is null then raise exception 'That church was not found.'; end if;
    boss := exists (select 1 from role_assignments r where r.user_id = p_user and r.revoked_at is null and r.verified_at is not null
                      and (r.role = 'platform_admin' or (r.role = 'church_admin' and r.church_id = p_church)));
    if not boss then raise exception 'Only the church admin can buy seats for this church.'; end if;
    if p_seats is null or p_seats < 1 then raise exception 'Enter how many seats you need.'; end if;
    select min(min_seats), max(seat_limit) into lo, hi from license_plans where kind = 'church' and active;
    l := private.current_church_license(p_church);
    if l.id is not null and l.status = 'active' then
      total := l.seats + p_seats; k := 'church_upgrade';
    else
      total := p_seats; k := 'church_new'; l := null;
      if p_seats < lo then raise exception 'The smallest purchase is % seats.', lo; end if;
    end if;
    if total > hi then raise exception 'For more than % seats in total, contact us and we’ll set it up.', to_char(hi, 'FM999,999'); end if;
    p := private.church_tier(total);
    if p.id is null then raise exception 'Seats aren''t available for that number right now.'; end if;
    amt := p_seats * p.price;
    rate := '$' || trim(to_char(p.price, 'FM999,990.00'));
    if k = 'church_upgrade' then
      d := ch.name || ' · ' || p_seats || ' more seat' || case when p_seats = 1 then '' else 's' end || ' at ' || rate || ' each (' || total || ' in total)';
    else
      d := ch.name || ' · ' || p_seats || ' seats at ' || rate || ' each (1 year)';
    end if;
  else
    raise exception 'Unknown purchase.';
  end if;
  if amt is null or amt < 0.5 then raise exception 'Nothing to pay for that choice.'; end if;
  insert into payments (kind, buyer_partner_id, buyer_email, church_id, plan_id, license_id, description, amount, discount, seats)
  values (k, pid, em, p_church, p.id, l.id, d, amt, disc, case when p_type = 'church' then p_seats end) returning id into pay;
  return json_build_object('payment_id', pay, 'amount_cents', (amt * 100)::int, 'description', d, 'email', em);
end $$;

create or replace function public.stripe_activate(p_session text, p_intent text, p_amount_cents int)
returns text language plpgsql security definer set search_path = public, private as $$
declare pay payments; s seasons; p license_plans; lid uuid;
begin
  select * into pay from payments where stripe_session_id = p_session for update;
  if pay.id is null then raise exception 'Payment not found.'; end if;
  if pay.status = 'paid' then return 'already'; end if;
  if p_amount_cents <> (pay.amount * 100)::int then raise exception 'Paid amount does not match.'; end if;
  select * into s from seasons where active limit 1;
  select * into p from license_plans where id = pay.plan_id;
  if pay.kind = 'individual' then
    insert into individual_seats (partner_id, season_id, plan_id, price, status, paid_at, expires_at)
    values (pay.buyer_partner_id, s.id, pay.plan_id, pay.amount, 'active', now(), now() + interval '1 year')
    on conflict (partner_id, season_id) do update set status = 'active', plan_id = excluded.plan_id, price = excluded.price, paid_at = now(), expires_at = now() + interval '1 year';
    insert into guest_passes (owner_partner_id, payment_id) values (pay.buyer_partner_id, pay.id) on conflict (payment_id) do nothing;
  elsif pay.kind = 'church_new' then
    insert into church_licenses (church_id, season_id, plan_id, seats, price, status, paid_at, expires_at)
    values (pay.church_id, s.id, pay.plan_id, coalesce(pay.seats, p.seat_limit), pay.amount, 'active', now(), now() + interval '1 year')
    on conflict (church_id, season_id) do update set plan_id = excluded.plan_id, seats = excluded.seats, price = excluded.price,
      status = 'active', paid_at = now(), expires_at = now() + interval '1 year', updated_at = now()
    returning id into lid;
    update payments set license_id = lid where id = pay.id;
  else
    update church_licenses set plan_id = p.id, seats = case when pay.seats is not null then seats + pay.seats else p.seat_limit end,
      price = price + pay.amount, updated_at = now()
      where id = pay.license_id;
  end if;
  update payments set status = 'paid', paid_at = now(), stripe_payment_intent = p_intent where id = pay.id;
  insert into audit_logs (actor_id, organization_id, action, resource_type, resource_id, metadata)
    values (null, pay.church_id, 'payment.paid', 'payment', pay.id::text, jsonb_build_object('amount', pay.amount, 'kind', pay.kind, 'seats', pay.seats));
  return 'paid';
end $$;

revoke execute on function private.church_tier(int) from public, anon;
grant execute on function private.church_tier(int) to authenticated;
revoke execute on function public.public_pricing() from public;
grant execute on function public.public_pricing() to anon, authenticated;
revoke execute on function public.purchase_options(uuid) from public, anon;
grant execute on function public.purchase_options(uuid) to authenticated;
revoke execute on function public.stripe_prepare(uuid, text, uuid, uuid, int), public.stripe_activate(text, text, int) from public, anon, authenticated;
grant execute on function public.stripe_prepare(uuid, text, uuid, uuid, int), public.stripe_activate(text, text, int) to service_role;
