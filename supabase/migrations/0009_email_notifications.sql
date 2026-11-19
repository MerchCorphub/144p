-- 0009: email notifications. Database events put emails in an outbox; the send-emails server
-- function sends them through Resend (secret RESEND_API_KEY). A one-minute cron job wakes it
-- only when something is waiting.
--   Church admins and group leaders: each new request to join their church (they can turn this off).
--   Platform admins: every new account, every join request, every payment, every new church.

create extension if not exists pg_net with schema extensions;

create table public.email_outbox (
  id bigserial primary key,
  to_email text not null,
  subject text not null,
  html text not null,
  body_text text not null,
  kind text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0,
  last_error text
);
create index email_outbox_waiting on public.email_outbox (id) where sent_at is null;
alter table public.email_outbox enable row level security;
-- No policies: only the server function (service role) reads or changes the outbox.

create table public.notification_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email_new_members boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.notification_settings enable row level security;
create policy ns_own on public.notification_settings for select to authenticated using (user_id = (select auth.uid()));

create or replace function public.my_notification_settings()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('email_new_members', coalesce((select email_new_members from notification_settings where user_id = auth.uid()), true),
                           'email', (select email from auth.users where id = auth.uid())) $$;

create or replace function public.set_notification_settings(p_new_members boolean)
returns void language sql security definer set search_path = public as $$
  insert into notification_settings (user_id, email_new_members) values (auth.uid(), p_new_members)
  on conflict (user_id) do update set email_new_members = excluded.email_new_members, updated_at = now() $$;

-- ---------- building emails ----------
create or replace function private.h(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;') $$;

create or replace function private.queue_email(p_to text, p_subject text, p_lines text[], p_button text, p_link text, p_footer text, p_kind text)
returns void language plpgsql security definer set search_path = public, private as $$
declare body text := ''; plain text := ''; l text;
begin
  if p_to is null or position('@' in p_to) = 0 then return; end if;
  foreach l in array p_lines loop
    body := body || '<p style="margin:0 0 12px;font-size:16px;line-height:1.5;color:#14284B">' || l || '</p>';
    plain := plain || replace(replace(replace(replace(regexp_replace(l, '<[^>]+>', '', 'g'), '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&amp;', '&') || E'\n\n';
  end loop;
  insert into email_outbox (to_email, subject, kind, body_text, html) values (p_to, p_subject, p_kind,
    plain || coalesce(p_button || ': ' || p_link || E'\n\n', '') || coalesce(p_footer, ''),
    '<div style="background:#F7F3EA;padding:24px 12px;font-family:Arial,Helvetica,sans-serif">'
    || '<div style="max-width:520px;margin:0 auto;background:#fff;border:1px solid #E6DFCC;border-radius:14px;overflow:hidden">'
    || '<div style="background:#0B2257;border-bottom:3px solid #D9A62B;padding:16px 20px;color:#fff;font-weight:bold;font-size:17px">Time4God Challenge'
    || '<div style="font-size:12px;color:#F2C94C;font-weight:bold;letter-spacing:1px">THE 144(P) PLAN</div></div>'
    || '<div style="padding:22px 20px">' || body
    || coalesce('<p style="margin:18px 0 6px"><a href="' || p_link || '" style="display:inline-block;background:#D9A62B;color:#0B2257;font-weight:bold;text-decoration:none;padding:12px 20px;border-radius:10px">' || p_button || '</a></p>', '')
    || '</div>'
    || coalesce('<div style="padding:12px 20px;border-top:1px solid #EEE;font-size:12px;color:#5A6A78">' || p_footer || '</div>', '')
    || '</div></div>');
end $$;

create or replace function private.admin_emails() returns setof text
language sql stable security definer set search_path = public as $$
  select distinct u.email::text from role_assignments r join auth.users u on u.id = r.user_id
  left join notification_settings n on n.user_id = r.user_id
  where r.role = 'platform_admin' and r.verified_at is not null and r.revoked_at is null and coalesce(n.email_new_members, true) $$;

-- ---------- events ----------
create or replace function private.on_new_partner() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare a text;
begin
  for a in select private.admin_emails() loop
    perform private.queue_email(a, 'New account: ' || new.first_name || ' ' || new.last_name,
      array['<strong>' || h(new.first_name || ' ' || new.last_name) || '</strong> (' || h(new.email) || ') just created a 144(P) Plan account.',
            'There is nothing to approve yet. When they enter a church code, that church''s leaders get a separate "New request to join" email and the request shows under Approvals.'],
      'Open the Admin Panel', 'https://time4god.app/admin.html', null, 'admin.new_account');
  end loop;
  return null;
end $$;

create or replace function private.on_join_request() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare p partners; c churches; a record; mail text; who text; verb text;
begin
  -- an approval (pending -> verified) is not a new request; a new church or a re-request is
  if tg_op = 'UPDATE' and new.church_id = old.church_id and not (new.status = 'pending' and old.status <> 'pending') then return null; end if;
  if new.status not in ('pending', 'verified') then return null; end if;
  select * into p from partners where id = new.partner_id;
  select * into c from churches where id = new.church_id;
  who := p.first_name || ' ' || p.last_name;
  verb := case when new.status = 'pending' then 'asked to join' else 'joined' end;
  -- leaders of that church who can approve and haven't turned these emails off
  for a in select distinct u.email::text as em from role_assignments r join auth.users u on u.id = r.user_id
           left join notification_settings n on n.user_id = r.user_id
           where r.church_id = new.church_id and r.role in ('church_admin', 'table_leader') and r.verified_at is not null and r.revoked_at is null
             and coalesce(n.email_new_members, true) and r.user_id <> p.auth_user_id loop
    perform private.queue_email(a.em,
      case when new.status = 'pending' then 'New request to join ' || c.name || ': ' || who else who || ' joined ' || c.name end,
      array['<strong>' || h(who) || '</strong> (' || h(p.email) || ') ' || verb || ' <strong>' || h(c.name) || '</strong> in the 144(P) Plan.',
            case when new.status = 'pending' then 'Please approve them in the Leader Console so they can read the book and join the Time4God Challenge.'
                 else 'No approval is needed. You can place them in a group in the Leader Console.' end],
      case when new.status = 'pending' then 'Review and approve' else 'Open the Leader Console' end, 'https://time4god.app/leader.html',
      'You get this because you lead ' || h(c.name) || '. To stop these emails, open the Leader Console and turn off "Email me about new members."',
      'leader.join_request');
  end loop;
  for mail in select private.admin_emails() loop
    perform private.queue_email(mail, 'Join request: ' || who || ' → ' || c.name,
      array['<strong>' || h(who) || '</strong> (' || h(p.email) || ') ' || verb || ' <strong>' || h(c.name) || '</strong>.'],
      'Open the Admin Panel', 'https://time4god.app/admin.html', null, 'admin.join_request');
  end loop;
  return null;
end $$;

create or replace function private.on_payment_paid() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare mail text;
begin
  if new.status <> 'paid' or old.status = 'paid' then return null; end if;
  for mail in select private.admin_emails() loop
    perform private.queue_email(mail, 'Payment received: $' || to_char(new.amount, 'FM999,990.00') || ' · ' || new.description,
      array['<strong>$' || to_char(new.amount, 'FM999,990.00') || '</strong> paid through Stripe.',
            h(new.description), 'Buyer: ' || h(coalesce((select first_name || ' ' || last_name from partners where id = new.buyer_partner_id), '')) || ' (' || h(coalesce(new.buyer_email, '')) || ')'],
      'See payments', 'https://time4god.app/admin.html', null, 'admin.payment');
  end loop;
  return null;
end $$;

create or replace function private.on_new_church() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare mail text;
begin
  for mail in select private.admin_emails() loop
    perform private.queue_email(mail, 'New church: ' || new.name,
      array['<strong>' || h(new.name) || '</strong>' || coalesce(' (' || h(nullif(concat_ws(', ', new.city, new.state), '')) || ')', '') || ' was added. Church code: <strong>' || h(new.code) || '</strong>.',
            'Next step: assign its church admin in Admin Panel › Churches.'],
      'Open Churches', 'https://time4god.app/admin.html', null, 'admin.new_church');
  end loop;
  return null;
end $$;

create trigger notify_new_partner after insert on public.partners for each row execute function private.on_new_partner();
create trigger notify_join after insert or update of status, church_id on public.memberships for each row execute function private.on_join_request();
create trigger notify_payment after update of status on public.payments for each row execute function private.on_payment_paid();
create trigger notify_new_church after insert on public.churches for each row execute function private.on_new_church();

-- ---------- grants ----------
revoke execute on function public.my_notification_settings(), public.set_notification_settings(boolean) from public, anon;
grant execute on function public.my_notification_settings(), public.set_notification_settings(boolean) to authenticated;
revoke execute on function private.queue_email(text, text, text[], text, text, text, text), private.admin_emails() from public, anon, authenticated;

-- 0009c: wake the send-emails function once a minute, only when something is waiting.
-- A random token in Supabase Vault (name 'notify_token') proves the call came from this database.
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'notify_token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'notify_token', 'Wakes the send-emails function');
  end if;
end $$;

create or replace function public.notify_token_ok(t text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(t = (select decrypted_secret from vault.decrypted_secrets where name = 'notify_token'), false) $$;
revoke execute on function public.notify_token_ok(text) from public, anon, authenticated;
grant execute on function public.notify_token_ok(text) to service_role;

create or replace function private.wake_email_sender() returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from email_outbox where sent_at is null and attempts < 5) then
    perform net.http_post(
      url := 'https://hevkjegnogadwybbmwjx.supabase.co/functions/v1/send-emails',
      headers := jsonb_build_object('Content-Type', 'application/json',
                   'x-notify-token', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_token')),
      body := '{}'::jsonb, timeout_milliseconds := 60000);
  end if;
end $$;
revoke execute on function private.wake_email_sender() from public, anon, authenticated;

select cron.schedule('send-emails', '* * * * *', 'select private.wake_email_sender()');
