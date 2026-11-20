-- 0019: email settings the platform admin can change in Admin Panel › Settings.
--  admin_emails  where "new account / join request / payment / new church / invoice" emails go
--                (comma-separated; blank = the sign-in email of each platform admin)
--  reply_to      where replies to app emails go
--  support_email shown to members, leaders and churches for questions
create table if not exists public.app_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

insert into public.app_settings (key, value) values
  ('admin_emails', null), ('reply_to', 'askpaul.pp@gmail.com'), ('support_email', 'askpaul.pp@gmail.com')
on conflict (key) do nothing;

create or replace function private.setting(k text) returns text
language sql stable security definer set search_path = public as $$
  select nullif(trim(value), '') from app_settings where key = k $$;

create or replace function private.valid_email(e text) returns boolean
language sql immutable as $$ select e ~* '^[A-Z0-9._%+''-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' $$;

-- Admin notification addresses: the list from Settings, or every platform admin's sign-in email
create or replace function private.admin_emails() returns setof text
language plpgsql stable security definer set search_path = public, private as $$
declare list text := private.setting('admin_emails');
begin
  if list is not null then
    return query select distinct lower(trim(x)) from unnest(string_to_array(list, ',')) x where private.valid_email(trim(x));
  else
    return query select distinct u.email::text from role_assignments r join auth.users u on u.id = r.user_id
      left join notification_settings n on n.user_id = r.user_id
      where r.role = 'platform_admin' and r.verified_at is not null and r.revoked_at is null and coalesce(n.email_new_members, true);
  end if;
end $$;

create or replace function public.admin_settings() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see settings.'; end if;
  return json_build_object(
    'admin_emails', private.setting('admin_emails'),
    'reply_to', private.setting('reply_to'),
    'support_email', private.setting('support_email'),
    'admin_default', (select string_agg(distinct u.email::text, ', ') from role_assignments r join auth.users u on u.id = r.user_id
                      where r.role = 'platform_admin' and r.verified_at is not null and r.revoked_at is null),
    'updated_at', (select max(updated_at) from app_settings));
end $$;

create or replace function public.admin_save_settings(p_admin_emails text, p_reply_to text, p_support text) returns void
language plpgsql security definer set search_path = public, private as $$
declare x text; clean text := '';
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can change settings.'; end if;
  foreach x in array string_to_array(coalesce(p_admin_emails, ''), ',') loop
    x := lower(trim(x));
    if x = '' then continue; end if;
    if not private.valid_email(x) then raise exception '"%" doesn''t look like an email address.', x; end if;
    clean := clean || case when clean = '' then '' else ', ' end || x;
  end loop;
  if nullif(trim(p_reply_to), '') is not null and not private.valid_email(trim(p_reply_to)) then raise exception 'Check the reply-to email address.'; end if;
  if nullif(trim(p_support), '') is not null and not private.valid_email(trim(p_support)) then raise exception 'Check the support email address.'; end if;
  insert into app_settings (key, value, updated_at, updated_by) values
    ('admin_emails', nullif(clean, ''), now(), auth.uid()),
    ('reply_to', nullif(lower(trim(p_reply_to)), ''), now(), auth.uid()),
    ('support_email', nullif(lower(trim(p_support)), ''), now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by;
end $$;

-- Sends a short test email to the admin notification addresses
create or replace function public.admin_send_test_email() returns int
language plpgsql security definer set search_path = public, private as $$
declare mail text; n int := 0;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can send a test.'; end if;
  for mail in select private.admin_emails() loop
    perform private.queue_email(mail, 'Test email from the Time4God Admin Panel',
      array['This is a test. Admin notices for new accounts, join requests, payments, invoices and new churches go to this address.',
            'If you reply to this email, your reply goes to: <strong>' || h(coalesce(private.setting('reply_to'), 'not set')) || '</strong>.'],
      'Open the Admin Panel', 'https://time4god.app/admin.html', null, 'admin.test');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Readable before sign-in: where people send questions
create or replace function public.public_contact() returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object('support_email', private.setting('support_email')) $$;

-- For the send-emails function
create or replace function public.email_settings() returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object('reply_to', private.setting('reply_to')) $$;

revoke execute on function private.setting(text), private.valid_email(text), private.admin_emails() from public, anon, authenticated;
revoke execute on function public.admin_settings(), public.admin_save_settings(text, text, text), public.admin_send_test_email() from public, anon;
grant execute on function public.admin_settings(), public.admin_save_settings(text, text, text), public.admin_send_test_email() to authenticated;
revoke execute on function public.public_contact() from public;
grant execute on function public.public_contact() to anon, authenticated;
revoke execute on function public.email_settings() from public, anon, authenticated;
grant execute on function public.email_settings() to service_role;
