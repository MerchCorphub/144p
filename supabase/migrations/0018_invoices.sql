-- 0018: pay by invoice for large church purchases ($20,000 and up).
-- The leader can still pay by card, or ask for a Stripe invoice: it's emailed to them, due in
-- 15 days, and can be paid by bank transfer (wire/ACH, to account details Stripe shows on the
-- invoice) or by card. Seats turn on only when Stripe reports the invoice paid. Paid invoices
-- are picked up every 15 minutes (and whenever the leader opens the Leader Console).

alter table public.payments add column if not exists method text not null default 'checkout';
alter table public.payments drop constraint if exists payments_method_check;
alter table public.payments add constraint payments_method_check check (method in ('checkout', 'invoice'));
alter table public.payments add column if not exists stripe_invoice_id text unique;
alter table public.payments add column if not exists invoice_number text;
alter table public.payments add column if not exists invoice_url text;
alter table public.payments add column if not exists due_date date;
alter table public.payments add column if not exists test boolean;
alter table public.payments drop constraint if exists payments_status_check;
alter table public.payments add constraint payments_status_check check (status in ('open', 'paid', 'expired', 'void'));
alter table public.churches add column if not exists stripe_customer_id text;

create or replace function private.invoice_min() returns numeric language sql immutable as $$ select 20000.00::numeric $$;
create or replace function private.invoice_days() returns int language sql immutable as $$ select 15 $$;

-- ---------- turning a payment into seats (shared by card checkout and invoices) ----------
create or replace function private.activate_payment(p_id uuid, p_intent text) returns text
language plpgsql security definer set search_path = public, private as $$
declare pay payments; s seasons; p license_plans; lid uuid;
begin
  select * into pay from payments where id = p_id for update;
  if pay.status = 'paid' then return 'already'; end if;
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
    values (null, pay.church_id, 'payment.paid', 'payment', pay.id::text, jsonb_build_object('amount', pay.amount, 'kind', pay.kind, 'seats', pay.seats, 'method', pay.method));
  return 'paid';
end $$;

create or replace function public.stripe_activate(p_session text, p_intent text, p_amount_cents int)
returns text language plpgsql security definer set search_path = public, private as $$
declare pay payments;
begin
  select * into pay from payments where stripe_session_id = p_session;
  if pay.id is null then raise exception 'Payment not found.'; end if;
  if pay.status = 'paid' then return 'already'; end if;
  if p_amount_cents <> (pay.amount * 100)::int then raise exception 'Paid amount does not match.'; end if;
  return private.activate_payment(pay.id, p_intent);
end $$;

-- ---------- invoices (called only by the stripe-pay server function) ----------
-- Checks before an invoice is created for a payment that stripe_prepare just started.
create or replace function public.stripe_invoice_context(p_payment uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare pay payments; ch churches; o payments;
begin
  select * into pay from payments where id = p_payment;
  if pay.id is null or pay.status <> 'open' or pay.church_id is null then raise exception 'Invoices are for church seat purchases.'; end if;
  if pay.amount < private.invoice_min() then
    raise exception 'Invoices are for purchases of $% or more. Please pay by card.', to_char(private.invoice_min(), 'FM999,999');
  end if;
  select * into ch from churches where id = pay.church_id;
  select * into o from payments where church_id = pay.church_id and method = 'invoice' and status = 'open' and id <> pay.id limit 1;
  if o.id is not null then
    raise exception 'Invoice % for % is already waiting for payment. Pay or cancel it before asking for another.', coalesce(o.invoice_number, ''), '$' || to_char(o.amount, 'FM999,990.00');
  end if;
  return json_build_object('church_id', ch.id, 'church_name', ch.name, 'customer_id', ch.stripe_customer_id, 'email', pay.buyer_email,
    'amount_cents', (pay.amount * 100)::int, 'description', pay.description, 'days', private.invoice_days());
end $$;

-- A payment that was started but never reached Stripe
create or replace function public.stripe_drop_payment(p_payment uuid) returns void
language sql security definer set search_path = public as $$
  delete from payments where id = p_payment and status = 'open' and stripe_session_id is null and stripe_invoice_id is null $$;

create or replace function public.stripe_set_customer(p_church uuid, p_customer text) returns void
language sql security definer set search_path = public as $$
  update churches set stripe_customer_id = p_customer where id = p_church $$;

create or replace function public.stripe_attach_invoice(p_payment uuid, p_invoice text, p_number text, p_url text, p_due date, p_test boolean)
returns void language plpgsql security definer set search_path = public, private as $$
declare pay payments; mail text;
begin
  update payments set method = 'invoice', stripe_invoice_id = p_invoice, invoice_number = p_number, invoice_url = p_url, due_date = p_due, test = p_test
  where id = p_payment and status = 'open' returning * into pay;
  if pay.id is null then return; end if;
  for mail in select private.admin_emails() loop
    perform private.queue_email(mail, 'Invoice sent: $' || to_char(pay.amount, 'FM999,990.00') || ' · ' || pay.description,
      array['Invoice <strong>' || h(coalesce(p_number, '')) || '</strong> for <strong>$' || to_char(pay.amount, 'FM999,990.00') || '</strong> was emailed to ' || h(coalesce(pay.buyer_email, 'the church admin')) || '.',
            h(pay.description), 'Due ' || to_char(p_due, 'FMMonth FMDD, YYYY') || '. The seats turn on when it’s paid.' || case when p_test then ' (Stripe test mode)' else '' end],
      'See payments', 'https://time4god.app/admin.html', null, 'admin.invoice');
  end loop;
end $$;

-- Open invoices to check with Stripe: all of them (scheduled check) or one person's churches
create or replace function public.stripe_open_invoices(p_user uuid default null) returns setof text
language sql stable security definer set search_path = public, private as $$
  select p.stripe_invoice_id from payments p
  where p.method = 'invoice' and p.status = 'open' and p.stripe_invoice_id is not null
    and (p_user is null
         or p.buyer_partner_id = (select id from partners where auth_user_id = p_user)
         or exists (select 1 from role_assignments r where r.user_id = p_user and r.revoked_at is null and r.verified_at is not null
                      and (r.role = 'platform_admin' or (r.role = 'church_admin' and r.church_id = p.church_id)))) $$;

create or replace function public.stripe_activate_invoice(p_invoice text, p_intent text, p_amount_cents int)
returns text language plpgsql security definer set search_path = public, private as $$
declare pay payments;
begin
  select * into pay from payments where stripe_invoice_id = p_invoice;
  if pay.id is null then raise exception 'Invoice not found.'; end if;
  if pay.status = 'paid' then return 'already'; end if;
  if p_amount_cents < (pay.amount * 100)::int then raise exception 'Paid amount does not match.'; end if;
  return private.activate_payment(pay.id, p_intent);
end $$;

create or replace function public.stripe_void_invoice(p_invoice text) returns void
language sql security definer set search_path = public as $$
  update payments set status = 'void' where stripe_invoice_id = p_invoice and status = 'open' $$;

-- ---------- what the pages see ----------
create or replace function public.church_invoices(cid uuid) returns table
  (id uuid, created_at timestamptz, description text, amount numeric, number text, url text, due_date date, status text, seats int)
language sql stable security definer set search_path = public, private as $$
  select p.id, p.created_at, p.description, p.amount, p.invoice_number, p.invoice_url, p.due_date, p.status, p.seats
  from payments p where p.church_id = cid and p.method = 'invoice' and p.stripe_invoice_id is not null
    and private.manages_church(cid) and (p.status = 'open' or p.created_at > now() - interval '60 days')
  order by p.created_at desc $$;

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
    'invoice_min', private.invoice_min(), 'invoice_days', private.invoice_days(),
    'open_invoice', (select json_build_object('number', invoice_number, 'amount', amount, 'url', invoice_url, 'due_date', due_date)
                     from payments where church_id = cid and method = 'invoice' and status = 'open' and stripe_invoice_id is not null limit 1),
    'tiers', (select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'min', p.min_seats, 'max', p.seat_limit, 'rate', p.price) order by p.min_seats), '[]'::json)
              from license_plans p where p.kind = 'church' and p.active));
end $$;

create or replace function public.public_pricing() returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object(
    'individual', (select price from license_plans where kind = 'individual' and active order by sort_order limit 1),
    'church_from', (select min(price) from license_plans where kind = 'church' and active),
    'church_top_rate', (select price from license_plans where kind = 'church' and active order by min_seats limit 1),
    'church_min_seats', (select min(min_seats) from license_plans where kind = 'church' and active),
    'per_seat', true, 'invoice_min', private.invoice_min(), 'invoice_days', private.invoice_days(),
    'church_plans', (select coalesce(json_agg(json_build_object('name', name, 'min', min_seats, 'seats', seat_limit, 'price', price) order by min_seats), '[]'::json)
                     from license_plans where kind = 'church' and active)) $$;

-- Payments tab: include invoices waiting for payment
drop function if exists public.admin_payments();
create function public.admin_payments()
returns table (id uuid, created_at timestamptz, paid_at timestamptz, kind text, description text, amount numeric, status text, buyer text, buyer_email text, church text,
               method text, invoice_number text, invoice_url text, due_date date, test boolean)
language sql stable security definer set search_path = public, private as $$
  select p.id, p.created_at, p.paid_at, p.kind, p.description, p.amount, p.status,
    (select pa.first_name || ' ' || pa.last_name from partners pa where pa.id = p.buyer_partner_id), p.buyer_email,
    (select c.name from churches c where c.id = p.church_id),
    p.method, p.invoice_number, p.invoice_url, p.due_date, coalesce(p.test, coalesce(p.stripe_session_id, '') like 'cs_test_%')
  from payments p where private.is_platform_admin() and (p.status <> 'open' or (p.method = 'invoice' and p.stripe_invoice_id is not null))
  order by coalesce(p.paid_at, p.created_at) desc $$;

-- Card checkouts left open are re-checked on return; invoices are checked separately
create or replace function public.my_open_payments()
returns table (stripe_session_id text) language sql stable security definer set search_path = public, private as $$
  select p.stripe_session_id from payments p
  where p.status = 'open' and p.method = 'checkout' and p.stripe_session_id is not null and p.created_at > now() - interval '2 days'
    and (p.buyer_partner_id = private.my_partner_id() or (p.church_id is not null and private.manages_church(p.church_id))) $$;

-- ---------- dashboard: invoice test mode counts as test; show invoices waiting ----------
do $$
declare d text;
begin
  d := pg_get_functiondef('private.admin_dashboard_base()'::regprocedure);
  d := replace(d, $q$coalesce(stripe_session_id, '') not like 'cs_test_%'$q$, 'not @@T@@');
  d := replace(d, $q$stripe_session_id like 'cs_test_%'$q$, '@@T@@');
  d := replace(d, '@@T@@', $q$coalesce(test, coalesce(stripe_session_id, '') like 'cs_test_%')$q$);
  execute d;
end $$;

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
      'overdue', (select count(*) from payments where method = 'invoice' and status = 'open' and stripe_invoice_id is not null and due_date < current_date and not coalesce(test, false)))
  ))::json;
end $$;

-- ---------- scheduled check of open invoices ----------
create or replace function private.wake_invoice_sync() returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from payments where method = 'invoice' and status = 'open' and stripe_invoice_id is not null) then
    perform net.http_post(
      url := 'https://hevkjegnogadwybbmwjx.supabase.co/functions/v1/stripe-pay',
      headers := jsonb_build_object('Content-Type', 'application/json',
                   'x-notify-token', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_token')),
      body := '{"action":"sync_invoices"}'::jsonb, timeout_milliseconds := 60000);
  end if;
end $$;
select cron.schedule('sync-invoices', '*/15 * * * *', 'select private.wake_invoice_sync()');

-- ---------- grants ----------
revoke execute on function private.activate_payment(uuid, text), private.wake_invoice_sync() from public, anon, authenticated;
revoke execute on function private.invoice_min(), private.invoice_days() from public, anon;
grant execute on function private.invoice_min(), private.invoice_days() to authenticated;
revoke execute on function public.stripe_activate(text, text, int), public.stripe_invoice_context(uuid), public.stripe_drop_payment(uuid), public.stripe_set_customer(uuid, text),
  public.stripe_attach_invoice(uuid, text, text, text, date, boolean), public.stripe_open_invoices(uuid), public.stripe_activate_invoice(text, text, int), public.stripe_void_invoice(text)
  from public, anon, authenticated;
grant execute on function public.stripe_activate(text, text, int), public.stripe_invoice_context(uuid), public.stripe_drop_payment(uuid), public.stripe_set_customer(uuid, text),
  public.stripe_attach_invoice(uuid, text, text, text, date, boolean), public.stripe_open_invoices(uuid), public.stripe_activate_invoice(text, text, int), public.stripe_void_invoice(text)
  to service_role;
revoke execute on function public.church_invoices(uuid), public.purchase_options(uuid), public.admin_payments(), public.my_open_payments(), public.admin_dashboard() from public, anon;
grant execute on function public.church_invoices(uuid), public.purchase_options(uuid), public.admin_payments(), public.my_open_payments(), public.admin_dashboard() to authenticated;
revoke execute on function public.public_pricing() from public;
grant execute on function public.public_pricing() to anon, authenticated;
