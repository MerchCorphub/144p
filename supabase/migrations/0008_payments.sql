-- 0008: Stripe payments. One-time payments that last one year (no automatic renewal).
-- Individuals buy a $10 app seat; church admins buy a seat pack or upgrade to a larger one
-- (paying the difference, same end date). Prices include tax. All sales are final.
-- Payments are started and confirmed only by the stripe-pay server function (service role).

alter table public.church_licenses add column if not exists paid_at timestamptz;
alter table public.church_licenses add column if not exists expires_at timestamptz;
alter table public.individual_seats add column if not exists paid_at timestamptz;
alter table public.individual_seats add column if not exists expires_at timestamptz;

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('individual', 'church_new', 'church_upgrade')),
  buyer_partner_id uuid references public.partners(id) on delete set null,
  buyer_email text,
  church_id uuid references public.churches(id) on delete set null,
  plan_id uuid references public.license_plans(id) on delete set null,
  license_id uuid references public.church_licenses(id) on delete set null,
  description text not null,
  amount numeric(10,2) not null check (amount > 0),
  currency text not null default 'usd',
  status text not null default 'open' check (status in ('open', 'paid', 'expired')),
  stripe_session_id text unique,
  stripe_payment_intent text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index on public.payments (buyer_partner_id);
create index on public.payments (church_id);
alter table public.payments enable row level security;
create policy pay_select on public.payments for select to authenticated
  using (buyer_partner_id = (select private.my_partner_id()) or (select private.is_platform_admin())
         or (church_id is not null and private.manages_church(church_id)));
-- No insert/update/delete policies: only the server function (service role) writes payments.

-- ---------- which license or seat counts right now ----------
-- A paid license lasts one year. If a season starts before it ends, it covers that whole season.
-- Licenses entered by hand (no end date) cover the season they were entered for.
create or replace function private.license_covers(p_season uuid, p_expires timestamptz, s public.seasons)
returns boolean language sql stable set search_path = public as $$
  select case when p_expires is null then p_season = s.id
              else p_expires > least(now(), s.start_date::timestamptz) end $$;

create or replace function private.current_church_license(cid uuid)
returns public.church_licenses language sql stable security definer set search_path = public, private as $$
  select l.* from church_licenses l, seasons s
  where s.active and l.church_id = cid and l.status <> 'canceled' and private.license_covers(l.season_id, l.expires_at, s)
  order by (l.status = 'active') desc, l.expires_at desc nulls last, l.created_at desc limit 1 $$;

create or replace function private.has_individual_seat(pid uuid)
returns boolean language sql stable security definer set search_path = public, private as $$
  select exists (select 1 from individual_seats i, seasons s
    where s.active and i.partner_id = pid and i.status = 'active' and private.license_covers(i.season_id, i.expires_at, s)) $$;

create or replace function private.my_unlocked_week() returns int
language plpgsql stable security definer set search_path = public, private as $$
declare s seasons; pid uuid := private.my_partner_id(); ok boolean := false; w int;
begin
  if private.is_platform_admin() then return 12; end if;
  select * into s from seasons where active limit 1;
  if s.id is null then return -1; end if;
  if pid is not null then
    select exists (select 1 from memberships m where m.partner_id = pid and m.status = 'verified'
                     and (private.current_church_license(m.church_id)).status = 'active')
        or private.has_individual_seat(pid)
      into ok;
  end if;
  if not ok then
    select exists (select 1 from role_assignments r
                   where r.user_id = auth.uid() and r.role in ('church_admin', 'table_leader') and r.verified_at is not null and r.revoked_at is null
                     and (private.current_church_license(r.church_id)).status = 'active')
      into ok;
  end if;
  if not ok then return -1; end if;
  w := floor((current_date - s.start_date) / 7.0)::int + 1;
  return greatest(0, least(12, w));
end $$;

drop function if exists public.church_seat_status(uuid);
create function public.church_seat_status(cid uuid)
returns table (plan_name text, seats int, used int, license_status text, season_name text, expires_at timestamptz, price numeric, license_id uuid)
language sql stable security definer set search_path = public, private as $$
  select p.name, l.seats, (select count(*)::int from memberships m where m.church_id = cid and m.status = 'verified'), l.status, s.name, l.expires_at, l.price, l.id
  from seasons s left join lateral (select * from private.current_church_license(cid)) l on l.id is not null
  left join license_plans p on p.id = l.plan_id
  where s.active and private.can_approve(cid) $$;

create or replace function public.approve_memberships(p_ids uuid[])
returns int language plpgsql security definer set search_path = public, private as $$
declare cid uuid; n int; used int; cap int;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  select min(church_id::text)::uuid, count(distinct church_id) into cid, n from memberships where id = any(p_ids) and status = 'pending';
  if n = 0 then return 0; end if;
  if n > 1 then raise exception 'Approve one church at a time.'; end if;
  if not private.can_approve(cid) then raise exception 'You are not a leader for this church.'; end if;
  perform pg_advisory_xact_lock(hashtext(cid::text));
  select count(*) into n from memberships where id = any(p_ids) and status = 'pending' and church_id = cid;
  cap := (private.current_church_license(cid)).seats;
  if cap is not null then
    select count(*) into used from memberships where church_id = cid and status = 'verified';
    if used + n > cap then raise exception 'Only % seats are left on this church''s license. Approve fewer people or add seats.', greatest(cap - used, 0); end if;
  end if;
  update memberships set status = 'verified' where id = any(p_ids) and status = 'pending' and church_id = cid;
  insert into audit_logs (actor_id, organization_id, action, resource_type, metadata) values (auth.uid(), cid, 'membership.approved', 'membership', jsonb_build_object('count', n));
  return n;
end $$;

create or replace function public.my_book_status()
returns table (unlocked_week int, season_name text, start_date date, join_cutoff date, membership text, church_name text, license_status text, seat_status text)
language plpgsql stable security definer set search_path = public, private as $$
declare s seasons; pid uuid := private.my_partner_id(); mst text; mcid uuid; mname text;
begin
  select * into s from seasons where active limit 1;
  select mm.status, mm.church_id, c.name into mst, mcid, mname from memberships mm join churches c on c.id = mm.church_id where mm.partner_id = pid and mm.status <> 'removed' limit 1;
  return query select private.my_unlocked_week(), s.name, s.start_date, s.join_cutoff, mst, mname,
    (private.current_church_license(mcid)).status,
    case when private.has_individual_seat(pid) then 'active' end;
end $$;

-- ---------- what can be bought ----------
create or replace function public.purchase_options(cid uuid default null)
returns json language plpgsql stable security definer set search_path = public, private as $$
declare l church_licenses; ind license_plans;
begin
  select * into ind from license_plans where kind = 'individual' and active order by sort_order limit 1;
  if cid is null then
    return json_build_object('individual_price', ind.price, 'has_seat', private.has_individual_seat(private.my_partner_id()));
  end if;
  if not private.manages_church(cid) then raise exception 'Only the church admin can buy seats for this church.'; end if;
  l := private.current_church_license(cid);
  return json_build_object(
    'current', case when l.id is not null then json_build_object('seats', l.seats, 'price', l.price, 'status', l.status, 'expires_at', l.expires_at,
                     'plan', (select name from license_plans where id = l.plan_id)) end,
    'used', (select count(*) from memberships where church_id = cid and status = 'verified'),
    'plans', (select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'seats', p.seat_limit, 'price', p.price,
                'due', case when l.status = 'active' then case when p.seat_limit > l.seats then greatest(p.price - l.price, 0) end
                            else p.price end) order by p.sort_order), '[]'::json)
              from license_plans p where p.kind = 'church' and p.active));
end $$;

-- ---------- called only by the stripe-pay server function ----------
create or replace function public.stripe_prepare(p_user uuid, p_type text, p_church uuid, p_plan uuid)
returns json language plpgsql security definer set search_path = public, private as $$
declare pid uuid; em text; s seasons; p license_plans; l church_licenses; amt numeric; k text; d text; pay uuid; ch churches; boss boolean;
begin
  select id, email into pid, em from partners where auth_user_id = p_user;
  if pid is null then raise exception 'Create your account first.'; end if;
  select * into s from seasons where active limit 1;
  if s.id is null then raise exception 'No season is open yet.'; end if;
  if p_type = 'individual' then
    select * into p from license_plans where kind = 'individual' and active order by sort_order limit 1;
    if p.id is null then raise exception 'Individual seats are not available right now.'; end if;
    if private.has_individual_seat(pid) then raise exception 'You already have the book in the app.'; end if;
    k := 'individual'; amt := p.price; d := 'Time4God Challenge · book in the app (1 year)';
  elsif p_type = 'church' then
    select * into ch from churches where id = p_church;
    if ch.id is null then raise exception 'That church was not found.'; end if;
    boss := exists (select 1 from role_assignments r where r.user_id = p_user and r.revoked_at is null and r.verified_at is not null
                      and (r.role = 'platform_admin' or (r.role = 'church_admin' and r.church_id = p_church)));
    if not boss then raise exception 'Only the church admin can buy seats for this church.'; end if;
    select * into p from license_plans where id = p_plan and kind = 'church' and active;
    if p.id is null then raise exception 'Choose a seat plan.'; end if;
    l := private.current_church_license(p_church);
    if l.id is not null and l.status = 'active' then
      if p.seat_limit <= l.seats then raise exception 'Choose a larger plan to add seats.'; end if;
      k := 'church_upgrade'; amt := p.price - l.price;
      d := ch.name || ' · upgrade to ' || p.name || ' (' || p.seat_limit || ' seats)';
    else
      k := 'church_new'; amt := p.price; l := null;
      d := ch.name || ' · ' || p.name || ' (' || p.seat_limit || ' seats, 1 year)';
    end if;
  else
    raise exception 'Unknown purchase.';
  end if;
  if amt is null or amt < 0.5 then raise exception 'Nothing to pay for that choice.'; end if;
  insert into payments (kind, buyer_partner_id, buyer_email, church_id, plan_id, license_id, description, amount)
  values (k, pid, em, p_church, p.id, l.id, d, amt) returning id into pay;
  return json_build_object('payment_id', pay, 'amount_cents', (amt * 100)::int, 'description', d, 'email', em);
end $$;

create or replace function public.stripe_attach_session(p_payment uuid, p_session text)
returns void language sql security definer set search_path = public as $$
  update payments set stripe_session_id = p_session where id = p_payment and status = 'open' $$;

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
  elsif pay.kind = 'church_new' then
    insert into church_licenses (church_id, season_id, plan_id, seats, price, status, paid_at, expires_at)
    values (pay.church_id, s.id, pay.plan_id, p.seat_limit, pay.amount, 'active', now(), now() + interval '1 year')
    on conflict (church_id, season_id) do update set plan_id = excluded.plan_id, seats = excluded.seats, price = excluded.price,
      status = 'active', paid_at = now(), expires_at = now() + interval '1 year', updated_at = now()
    returning id into lid;
    update payments set license_id = lid where id = pay.id;
  else
    update church_licenses set plan_id = p.id, seats = p.seat_limit, price = price + pay.amount, updated_at = now()
      where id = pay.license_id;
  end if;
  update payments set status = 'paid', paid_at = now(), stripe_payment_intent = p_intent where id = pay.id;
  insert into audit_logs (actor_id, organization_id, action, resource_type, resource_id, metadata)
    values (null, pay.church_id, 'payment.paid', 'payment', pay.id::text, jsonb_build_object('amount', pay.amount, 'kind', pay.kind));
  return 'paid';
end $$;

-- Payments the signed-in person started that Stripe hasn't confirmed yet (to check on return)
create or replace function public.my_open_payments()
returns table (stripe_session_id text) language sql stable security definer set search_path = public, private as $$
  select p.stripe_session_id from payments p
  where p.status = 'open' and p.stripe_session_id is not null and p.created_at > now() - interval '2 days'
    and (p.buyer_partner_id = private.my_partner_id() or (p.church_id is not null and private.manages_church(p.church_id))) $$;

create or replace function public.admin_payments()
returns table (id uuid, created_at timestamptz, paid_at timestamptz, kind text, description text, amount numeric, status text, buyer text, buyer_email text, church text)
language sql stable security definer set search_path = public, private as $$
  select p.id, p.created_at, p.paid_at, p.kind, p.description, p.amount, p.status,
    (select pa.first_name || ' ' || pa.last_name from partners pa where pa.id = p.buyer_partner_id), p.buyer_email,
    (select c.name from churches c where c.id = p.church_id)
  from payments p where private.is_platform_admin() and p.status <> 'open'
  order by coalesce(p.paid_at, p.created_at) desc $$;

-- ---------- grants ----------
revoke execute on function public.stripe_prepare(uuid, text, uuid, uuid), public.stripe_attach_session(uuid, text), public.stripe_activate(text, text, int) from public, anon, authenticated;
grant execute on function public.stripe_prepare(uuid, text, uuid, uuid), public.stripe_attach_session(uuid, text), public.stripe_activate(text, text, int) to service_role;
revoke execute on function public.purchase_options(uuid), public.my_open_payments(), public.admin_payments(), public.church_seat_status(uuid) from public, anon;
grant execute on function public.purchase_options(uuid), public.my_open_payments(), public.admin_payments(), public.church_seat_status(uuid) to authenticated;
revoke execute on function private.license_covers(uuid, timestamptz, public.seasons), private.current_church_license(uuid), private.has_individual_seat(uuid) from public, anon;
grant execute on function private.license_covers(uuid, timestamptz, public.seasons), private.current_church_license(uuid), private.has_individual_seat(uuid) to authenticated;

-- 0008b: abandoned checkouts (Stripe expires them after 24 hours) stop being re-checked
create or replace function public.stripe_expire(p_session text)
returns void language sql security definer set search_path = public as $$
  update payments set status = 'expired' where stripe_session_id = p_session and status = 'open' $$;
revoke execute on function public.stripe_expire(text) from public, anon, authenticated;
grant execute on function public.stripe_expire(text) to service_role;
