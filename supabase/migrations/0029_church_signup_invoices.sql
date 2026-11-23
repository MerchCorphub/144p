-- 0029: church sign-up (register → pricing → checkout) and Time4God invoices.
--  * Churches register with billing details, then buy seats while waiting for approval.
--    Pete approves afterwards; members can't join until then.
--  * Every church purchase gets a Time4God invoice document (PDF made by the invoice-pdf
--    function, stored in the private "invoices" bucket, emailed to the church as an attachment):
--      - card purchases: a PAID invoice (receipt)
--      - invoice purchases ($20,000+): an OPEN invoice, payable online (Stripe link), by check or by wire
--      - invoices the admin creates by hand (any amount): check or wire
--  * The admin marks check/wire invoices paid; that turns the seats on.

alter table public.churches add column if not exists billing_name text;

-- ---------- settings printed on invoices (Admin Panel › Settings) ----------
insert into public.app_settings (key, value) values
  ('invoice_payable_to', 'Merch Corporation'), ('invoice_address', null), ('invoice_wire', null),
  ('invoice_terms', 'All sales are final. Prices include tax. Seats turn on when payment is received.')
on conflict (key) do nothing;

create or replace function public.admin_invoice_settings() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see invoice settings.'; end if;
  return json_build_object('payable_to', private.setting('invoice_payable_to'), 'address', private.setting('invoice_address'),
    'wire', private.setting('invoice_wire'), 'terms', private.setting('invoice_terms'));
end $$;

create or replace function public.admin_save_invoice_settings(p_payable_to text, p_address text, p_wire text, p_terms text) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can change invoice settings.'; end if;
  insert into app_settings (key, value, updated_at, updated_by) values
    ('invoice_payable_to', nullif(trim(p_payable_to), ''), now(), auth.uid()), ('invoice_address', nullif(trim(p_address), ''), now(), auth.uid()),
    ('invoice_wire', nullif(trim(p_wire), ''), now(), auth.uid()), ('invoice_terms', nullif(trim(p_terms), ''), now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by;
end $$;

-- ---------- who may buy for a church: its managers, or the person whose request is waiting ----------
create or replace function private.can_buy_for(cid uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce(private.manages_church(cid), false)
      or exists (select 1 from churches c where c.id = cid and c.status = 'pending' and c.requested_by = private.my_partner_id()) $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.stripe_prepare(uuid,text,uuid,uuid,int)'::regprocedure);
  d := replace(d, $q$and (r.role = 'platform_admin' or (r.role = 'church_admin' and r.church_id = p_church)));$q$,
                  $q$and (r.role = 'platform_admin' or (r.role in ('church_admin', 'account_manager') and r.church_id = p_church)))
            or (ch.status = 'pending' and ch.requested_by = pid);$q$);
  if position('ch.requested_by = pid' in d) = 0 then raise exception 'stripe_prepare not updated'; end if;
  execute d;
  d := pg_get_functiondef('public.purchase_options(uuid)'::regprocedure);
  d := replace(d, 'if not private.manages_church(cid) then raise', 'if not private.can_buy_for(cid) then raise');
  if position('can_buy_for' in d) = 0 then raise exception 'purchase_options not updated'; end if;
  execute d;
end $$;

-- ---------- registration ----------
create or replace function public.register_church(p_kind text, p_name text, p_address text, p_city text, p_state text, p_zip text,
  p_phone text, p_website text, p_contact text, p_role text, p_billing_email text, p_note text) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); c churches; r json; em text := lower(nullif(trim(p_billing_email), ''));
begin
  if me is null then raise exception 'Create your free account first.'; end if;
  if em is not null and not private.valid_email(em) then raise exception 'Check the billing email address.'; end if;
  if nullif(trim(p_address), '') is null or nullif(trim(p_city), '') is null or nullif(trim(p_state), '') is null then
    raise exception 'Enter the street address, city and state for your invoice.';
  end if;
  select * into c from churches where requested_by = me and status = 'pending' order by created_at desc limit 1;
  if c.id is null then
    r := public.request_organization(p_kind, p_name, p_city, p_state, p_phone, p_website, p_role, p_note);
    select * into c from churches where id = (r->>'id')::uuid;
  else
    if nullif(trim(p_name), '') is null then raise exception 'Enter the % name.', case when p_kind = 'group' then 'group' else 'church' end; end if;
    update churches set kind = case when p_kind in ('church', 'group') then p_kind else kind end, name = trim(p_name),
      city = nullif(trim(p_city), ''), state = nullif(upper(trim(p_state)), ''), phone = nullif(trim(p_phone), ''), website = nullif(trim(p_website), ''),
      request_note = nullif(trim(concat_ws(' · ', nullif(trim(p_role), ''), nullif(trim(p_note), ''))), '')
    where id = c.id;
  end if;
  update churches set address = nullif(trim(p_address), ''), postal_code = nullif(trim(p_zip), ''),
    billing_name = nullif(trim(p_contact), ''), contact_email = coalesce(em, (select email from partners where id = me))
  where id = c.id returning * into c;
  return json_build_object('id', c.id, 'name', c.name, 'kind', c.kind, 'status', c.status);
end $$;

-- ---------- invoice documents ----------
create sequence if not exists public.invoice_number_seq start 1001;
create table if not exists public.invoice_docs (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  kind text not null default 'invoice' check (kind in ('invoice', 'receipt')),
  church_id uuid references public.churches(id) on delete set null,
  payment_id uuid unique references public.payments(id) on delete set null,
  bill_to_name text, bill_to_contact text, bill_to_email text, bill_to_address text,
  description text not null, seats int, unit_price numeric(10,2), amount numeric(10,2) not null,
  issued_at timestamptz not null default now(), due_date date,
  status text not null default 'open' check (status in ('open', 'paid', 'void')),
  paid_at timestamptz, paid_method text, paid_reference text,
  stripe_url text, pdf_path text, pdf_dirty boolean not null default true, email_pending boolean not null default true,
  emailed_at timestamptz, test boolean not null default false, created_by uuid
);
create index if not exists invoice_docs_church on public.invoice_docs (church_id);
alter table public.invoice_docs enable row level security;
revoke all on public.invoice_docs from anon, authenticated;

alter table public.email_outbox add column if not exists attachments jsonb;

insert into storage.buckets (id, name, public) values ('invoices', 'invoices', false) on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'invoices_read') then
    create policy invoices_read on storage.objects for select to authenticated
      using (bucket_id = 'invoices' and (private.is_platform_admin() or private.can_buy_for(((storage.foldername(name))[1])::uuid)));
  end if;
end $$;

-- The sign-up page picks up where the person left off
create or replace function public.my_church_signup() returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object('church', (select json_build_object('id', c.id, 'name', c.name, 'kind', c.kind, 'status', c.status, 'code', case when c.status = 'active' then c.code end,
      'address', c.address, 'city', c.city, 'state', c.state, 'zip', c.postal_code, 'phone', c.phone, 'website', c.website, 'contact', c.billing_name,
      'billing_email', c.contact_email, 'note', c.request_note,
      'license', (select json_build_object('seats', l.seats, 'status', l.status, 'expires_at', l.expires_at) from private.current_church_license(c.id) l where l.id is not null),
      'open_invoice', (select json_build_object('number', d.number, 'amount', d.amount, 'due_date', d.due_date, 'url', d.stripe_url) from invoice_docs d where d.church_id = c.id and d.status = 'open' order by d.issued_at desc limit 1))
    from churches c where c.requested_by = private.my_partner_id() and c.status in ('pending', 'active') order by c.created_at desc limit 1),
    'email', (select email from partners where id = private.my_partner_id()),
    'name', (select first_name || ' ' || last_name from partners where id = private.my_partner_id())) $$;

-- Makes (or refreshes) the invoice document for a church payment
create or replace function private.upsert_invoice_doc(p_payment uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare pay payments; c churches; d invoice_docs; rate numeric; addr text;
begin
  select * into pay from payments where id = p_payment;
  if pay.id is null or pay.church_id is null or pay.kind = 'individual' then return null; end if;
  select * into c from churches where id = pay.church_id;
  select * into d from invoice_docs where payment_id = pay.id;
  rate := case when coalesce(pay.seats, 0) > 0 then round(pay.amount / pay.seats, 2) end;
  addr := nullif(concat_ws(E'\n', c.address, nullif(concat_ws(', ', c.city, nullif(trim(concat_ws(' ', c.state, c.postal_code)), '')), '')), '');
  if d.id is null then
    insert into invoice_docs (number, kind, church_id, payment_id, bill_to_name, bill_to_contact, bill_to_email, bill_to_address, description, seats, unit_price, amount,
      due_date, status, paid_at, paid_method, stripe_url, test, created_by)
    values ('T4G-' || to_char(now(), 'YYYY') || '-' || nextval('invoice_number_seq'),
      case when pay.status = 'paid' and pay.method = 'checkout' then 'receipt' else 'invoice' end,
      c.id, pay.id, c.name, coalesce(c.billing_name, (select first_name || ' ' || last_name from partners where id = pay.buyer_partner_id)),
      coalesce(c.contact_email, pay.buyer_email), addr, pay.description, pay.seats, rate, pay.amount,
      case when pay.status = 'paid' then null else coalesce(pay.due_date, current_date + private.invoice_days()) end,
      case when pay.status = 'paid' then 'paid' else 'open' end, pay.paid_at,
      case when pay.status = 'paid' then case when pay.method = 'checkout' then 'card' else 'online' end end,
      pay.invoice_url, coalesce(pay.test, coalesce(pay.stripe_session_id, '') like 'cs_test_%'), auth.uid())
    returning * into d;
  else
    update invoice_docs set status = case when pay.status = 'paid' then 'paid' when pay.status = 'void' then 'void' else status end,
      paid_at = coalesce(paid_at, pay.paid_at), paid_method = coalesce(paid_method, case when pay.status = 'paid' then case when pay.method = 'checkout' then 'card' else 'online' end end),
      stripe_url = coalesce(pay.invoice_url, stripe_url), due_date = coalesce(due_date, pay.due_date),
      pdf_dirty = true, email_pending = email_pending or (pay.status = 'paid' and status <> 'paid')
    where id = d.id returning * into d;
  end if;
  return d.id;
end $$;

-- Payments trigger: every church payment that is invoiced or paid gets its document
create or replace function private.on_church_payment_doc() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.church_id is null or new.kind = 'individual' then return null; end if;
  if (new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid'))
     or (new.stripe_invoice_id is not null and (tg_op = 'INSERT' or old.stripe_invoice_id is null))
     or (new.status = 'void' and tg_op = 'UPDATE' and old.status <> 'void')
     or (new.method = 'invoice' and new.stripe_invoice_id is null and tg_op = 'UPDATE' and old.method <> 'invoice') then
    perform private.upsert_invoice_doc(new.id);
  end if;
  return null;
end $$;
create trigger church_payment_doc after insert or update on public.payments for each row execute function private.on_church_payment_doc();

-- Admin: an invoice by hand (check or wire), for any number of seats
create or replace function public.admin_create_invoice(p_church uuid, p_seats int, p_days int default 15, p_note text default null) returns json
language plpgsql security definer set search_path = public, private as $$
declare j json; pid uuid; doc uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only an admin can create invoices.'; end if;
  j := public.stripe_prepare(auth.uid(), 'church', p_church, null, p_seats);
  pid := (j->>'payment_id')::uuid;
  update payments set method = 'invoice', due_date = current_date + coalesce(p_days, 15),
    description = description || coalesce(' · ' || nullif(trim(p_note), ''), '')
  where id = pid;
  select id into doc from invoice_docs where payment_id = pid;
  return json_build_object('payment_id', pid, 'doc_id', doc, 'number', (select number from invoice_docs where id = doc));
end $$;

-- Mark an invoice paid (check, wire, or other) and turn the seats on. Called by stripe-pay after
-- it has also marked any Stripe invoice paid outside Stripe.
create or replace function public.stripe_mark_doc_paid(p_doc uuid, p_method text, p_reference text, p_user uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare d invoice_docs; r text;
begin
  if not exists (select 1 from role_assignments where user_id = p_user and role = 'platform_admin' and verified_at is not null and revoked_at is null) then
    raise exception 'Only an admin can mark invoices paid.';
  end if;
  select * into d from invoice_docs where id = p_doc for update;
  if d.id is null then raise exception 'Invoice not found.'; end if;
  if d.status = 'paid' then return 'already'; end if;
  if d.status = 'void' then raise exception 'This invoice was canceled.'; end if;
  update invoice_docs set paid_method = coalesce(nullif(trim(p_method), ''), 'other'), paid_reference = nullif(trim(p_reference), '') where id = d.id;
  r := private.activate_payment(d.payment_id, null);
  perform private.upsert_invoice_doc(d.payment_id);
  return r;
end $$;

create or replace function public.stripe_void_doc(p_doc uuid, p_user uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare d invoice_docs;
begin
  if not exists (select 1 from role_assignments where user_id = p_user and role = 'platform_admin' and verified_at is not null and revoked_at is null) then
    raise exception 'Only an admin can cancel invoices.';
  end if;
  select * into d from invoice_docs where id = p_doc for update;
  if d.id is null or d.status <> 'open' then raise exception 'Only an open invoice can be canceled.'; end if;
  update payments set status = 'void' where id = d.payment_id and status = 'open';
  update invoice_docs set status = 'void', pdf_dirty = true where id = d.id;
  return (select stripe_invoice_id from payments where id = d.payment_id);
end $$;

-- For the invoice-pdf function
create or replace function public.invoice_jobs() returns json
language sql stable security definer set search_path = public, private as $$
  select coalesce(json_agg(json_build_object('doc', to_jsonb(d), 'payable_to', private.setting('invoice_payable_to'), 'address', private.setting('invoice_address'),
      'wire', private.setting('invoice_wire'), 'terms', private.setting('invoice_terms'), 'support', private.setting('support_email'),
      'admins', (select array_agg(x) from private.admin_emails() x))), '[]'::json)
  from (select * from invoice_docs where pdf_dirty or email_pending order by issued_at limit 20) d $$;

create or replace function public.invoice_job_done(p_doc uuid, p_path text, p_emailed boolean) returns void
language plpgsql security definer set search_path = public, private as $$
declare d invoice_docs; money text; lines text[];
begin
  update invoice_docs set pdf_path = coalesce(p_path, pdf_path), pdf_dirty = false where id = p_doc returning * into d;
  if not p_emailed or not d.email_pending then return; end if;
  money := '$' || to_char(d.amount, 'FM999,999,990.00');
  if d.status = 'paid' then
    lines := array['Thank you! We received ' || money || ' for <strong>' || h(d.bill_to_name) || '</strong>.', h(d.description),
                   'Your paid invoice <strong>' || d.number || '</strong> is attached for your records.'];
  else
    lines := array['Here is invoice <strong>' || d.number || '</strong> for <strong>' || h(d.bill_to_name) || '</strong>: ' || money || ', due ' || to_char(d.due_date, 'FMMonth FMDD, YYYY') || '.',
                   h(d.description),
                   'The invoice is attached. You can pay ' || case when d.stripe_url is not null then 'online with the button below (card, ACH or bank wire), ' else '' end || 'by check or by wire. The details are on the invoice.',
                   'Your seats turn on as soon as your payment is received.'];
  end if;
  perform private.queue_email(d.bill_to_email,
    case when d.status = 'paid' then 'Payment received · Invoice ' || d.number else 'Invoice ' || d.number || ' · ' || money || ' due ' || to_char(d.due_date, 'FMMon FMDD') end,
    lines, case when d.status = 'open' and d.stripe_url is not null then 'View and pay invoice' end, case when d.status = 'open' then d.stripe_url end,
    'Questions? Reply to this email.' || case when d.test then ' (Stripe test mode)' else '' end, 'church.invoice');
  update email_outbox set attachments = jsonb_build_array(jsonb_build_object('path', d.pdf_path, 'filename', d.number || '.pdf'))
  where id = (select max(id) from email_outbox where kind = 'church.invoice' and to_email = d.bill_to_email);
  update invoice_docs set email_pending = false, emailed_at = now() where id = d.id;
end $$;

-- Admin: send the invoice email again
create or replace function public.admin_email_invoice(p_doc uuid) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only an admin can send invoices.'; end if;
  update invoice_docs set email_pending = true where id = p_doc;
end $$;

create or replace function private.wake_invoice_pdf() returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from invoice_docs where pdf_dirty or email_pending) then
    perform net.http_post(url := 'https://hevkjegnogadwybbmwjx.supabase.co/functions/v1/invoice-pdf',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-token', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_token')),
      body := '{}'::jsonb, timeout_milliseconds := 60000);
  end if;
end $$;
select cron.schedule('invoice-pdf', '* * * * *', 'select private.wake_invoice_pdf()');

-- ---------- Licenses tab: every church with approval, seats, payments and invoices ----------
create or replace function public.admin_license_overview() returns json
language sql stable security definer set search_path = public, private as $$
  select coalesce(json_agg(x order by x.pending desc, x.name), '[]'::json) from (
    select c.id, c.name, c.kind, c.status, c.status = 'pending' as pending, c.code, c.city, c.state, c.created_at,
      c.billing_name, c.contact_email,
      (select first_name || ' ' || last_name from partners where id = c.requested_by) as requester,
      l.id as license_id, l.seats, l.status as license_status, l.expires_at, l.price as license_price,
      (select count(*) from memberships m where m.church_id = c.id and m.status = 'verified') as used,
      (select coalesce(json_agg(json_build_object('id', d.id, 'number', d.number, 'kind', d.kind, 'status', d.status, 'amount', d.amount, 'seats', d.seats,
          'issued_at', d.issued_at, 'due_date', d.due_date, 'paid_at', d.paid_at, 'paid_method', d.paid_method, 'paid_reference', d.paid_reference,
          'stripe_url', d.stripe_url, 'pdf_path', d.pdf_path, 'emailed_at', d.emailed_at, 'test', d.test, 'description', d.description) order by d.issued_at desc), '[]'::json)
        from invoice_docs d where d.church_id = c.id) as invoices
    from churches c left join lateral (select * from private.current_church_license(c.id)) l on true
    where c.status in ('pending', 'active') and (private.is_platform_admin() or private.is_account_manager(c.id))) x $$;

-- Leader Console: the church's own invoices
create or replace function public.church_invoice_docs(cid uuid) returns json
language sql stable security definer set search_path = public, private as $$
  select coalesce(json_agg(json_build_object('id', d.id, 'number', d.number, 'kind', d.kind, 'status', d.status, 'amount', d.amount, 'issued_at', d.issued_at,
    'due_date', d.due_date, 'paid_at', d.paid_at, 'stripe_url', d.stripe_url, 'pdf_path', d.pdf_path, 'description', d.description) order by d.issued_at desc), '[]'::json)
  from invoice_docs d where d.church_id = cid and private.can_buy_for(cid) $$;

-- Payments made before this existed get their documents too (no email)
insert into invoice_docs (number, kind, church_id, payment_id, bill_to_name, bill_to_email, description, seats, amount, status, paid_at, paid_method, stripe_url, email_pending, test)
select 'T4G-' || to_char(p.created_at, 'YYYY') || '-' || nextval('invoice_number_seq'), case when p.method = 'checkout' then 'receipt' else 'invoice' end,
  p.church_id, p.id, c.name, coalesce(c.contact_email, p.buyer_email), p.description, p.seats, p.amount,
  case when p.status = 'paid' then 'paid' when p.status = 'void' then 'void' else 'open' end, p.paid_at,
  case when p.status = 'paid' then case when p.method = 'checkout' then 'card' else 'online' end end, p.invoice_url, false, coalesce(p.test, false)
from payments p join churches c on c.id = p.church_id
where p.kind <> 'individual' and (p.status = 'paid' or p.stripe_invoice_id is not null)
on conflict (payment_id) do nothing;

-- ---------- grants ----------
revoke execute on function private.can_buy_for(uuid), private.upsert_invoice_doc(uuid), private.on_church_payment_doc(), private.wake_invoice_pdf() from public, anon;
grant execute on function private.can_buy_for(uuid) to authenticated;
revoke execute on function public.register_church(text, text, text, text, text, text, text, text, text, text, text, text), public.my_church_signup(),
  public.admin_invoice_settings(), public.admin_save_invoice_settings(text, text, text, text), public.admin_create_invoice(uuid, int, int, text),
  public.admin_email_invoice(uuid), public.admin_license_overview(), public.church_invoice_docs(uuid) from public, anon;
grant execute on function public.register_church(text, text, text, text, text, text, text, text, text, text, text, text), public.my_church_signup(),
  public.admin_invoice_settings(), public.admin_save_invoice_settings(text, text, text, text), public.admin_create_invoice(uuid, int, int, text),
  public.admin_email_invoice(uuid), public.admin_license_overview(), public.church_invoice_docs(uuid) to authenticated;
revoke execute on function public.stripe_mark_doc_paid(uuid, text, text, uuid), public.stripe_void_doc(uuid, uuid), public.invoice_jobs(), public.invoice_job_done(uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function public.stripe_mark_doc_paid(uuid, text, text, uuid), public.stripe_void_doc(uuid, uuid), public.invoice_jobs(), public.invoice_job_done(uuid, text, boolean) to service_role;
