-- 0037: Opt-in "news and offers" email, with one-click unsubscribe, and Admin Panel › Announcements.
--  * Off by default. Members turn it on at sign-up or in My Account.
--  * Every announcement carries an unsubscribe link and the mailing address from Settings (CAN-SPAM).
--  * Phone numbers are never used for this.

alter table public.partners add column if not exists news_email boolean not null default false;
alter table public.partners add column if not exists news_email_at timestamptz;
alter table public.partners add column if not exists news_token text unique default replace(gen_random_uuid()::text, '-', '');
update public.partners set news_token = replace(gen_random_uuid()::text, '-', '') where news_token is null;

create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  subject text not null, body text not null, button_text text, button_link text,
  test boolean not null default false, recipients int not null default 0,
  created_at timestamptz not null default now(), created_by uuid
);
alter table public.announcements enable row level security;
revoke all on public.announcements from anon, authenticated;

create or replace function public.my_news_email() returns boolean
language sql stable security definer set search_path = public, private as $$ select news_email from partners where id = private.my_partner_id() $$;

create or replace function public.set_my_news_email(p_on boolean) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id();
begin
  if me is null then raise exception 'Please sign in again.'; end if;
  update partners set news_email = coalesce(p_on, false), news_email_at = now(),
    news_token = coalesce(news_token, replace(gen_random_uuid()::text, '-', '')) where id = me;
  return coalesce(p_on, false);
end $$;

-- One click from the email; no sign-in needed
create or replace function public.news_unsubscribe(p_token text) returns json
language plpgsql security definer set search_path = public, private as $$
declare p partners;
begin
  update partners set news_email = false, news_email_at = now() where news_token = trim(p_token) returning * into p;
  if p.id is null then return json_build_object('ok', false); end if;
  return json_build_object('ok', true, 'email', regexp_replace(p.email, '^(.).*(@.*)$', '\1•••\2'));
end $$;

create or replace function public.admin_announcements() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see this.'; end if;
  return json_build_object(
    'opted_in', (select count(*) from partners where news_email),
    'accounts', (select count(*) from partners),
    'address', private.setting('invoice_address'),
    'sent', (select coalesce(json_agg(json_build_object('id', a.id, 'subject', a.subject, 'test', a.test, 'recipients', a.recipients, 'created_at', a.created_at) order by a.created_at desc), '[]'::json)
             from (select * from announcements order by created_at desc limit 30) a));
end $$;

create or replace function public.admin_send_announcement(p_subject text, p_body text, p_button_text text, p_button_link text, p_test boolean) returns json
language plpgsql security definer set search_path = public, private as $$
declare addr text := private.setting('invoice_address'); lines text[]; para text; n int := 0; r record; foot text; btn text; lnk text;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can send announcements.'; end if;
  if nullif(trim(p_subject), '') is null or nullif(trim(p_body), '') is null then raise exception 'Write a subject and a message.'; end if;
  if nullif(trim(addr), '') is null then raise exception 'Add your mailing address first (Settings › What prints on invoices). The law requires it on every announcement.'; end if;
  btn := nullif(trim(p_button_text), ''); lnk := nullif(trim(p_button_link), '');
  if (btn is null) <> (lnk is null) then raise exception 'Give the button both a label and a link, or leave both empty.'; end if;
  if lnk is not null and lnk !~ '^https://' then raise exception 'The button link must start with https://'; end if;
  lines := array[]::text[];
  foreach para in array regexp_split_to_array(trim(p_body), E'\n\\s*\n') loop
    lines := lines || replace(h(trim(para)), E'\n', '<br>');
  end loop;
  for r in
    select p.email, p.first_name, p.news_token from partners p
    where (p_test and p.email in (select x from private.admin_emails() x))
       or (not coalesce(p_test, false) and p.news_email)
  loop
    foot := 'You’re getting this because you asked for news and offers from Time4God Challenge. '
      || '<a href="https://time4god.app/unsubscribe.html?t=' || r.news_token || '" style="color:#5A6A78">Unsubscribe</a> any time.<br>'
      || 'Merch Corporation · ' || h(replace(addr, E'\n', ', '));
    perform private.queue_email(r.email, case when p_test then '[Test] ' else '' end || trim(p_subject), lines, btn, lnk, foot, 'news');
    n := n + 1;
  end loop;
  -- Test sends also go to admin emails that have no account
  if p_test and n = 0 then
    for r in select x as email from private.admin_emails() x loop
      perform private.queue_email(r.email, '[Test] ' || trim(p_subject), lines, btn, lnk,
        'Test copy. Members see an Unsubscribe link here.<br>Merch Corporation · ' || h(replace(addr, E'\n', ', ')), 'news');
      n := n + 1;
    end loop;
  end if;
  insert into announcements (subject, body, button_text, button_link, test, recipients, created_by)
  values (trim(p_subject), p_body, btn, lnk, coalesce(p_test, false), n, auth.uid());
  return json_build_object('sent', n, 'test', coalesce(p_test, false));
end $$;

revoke execute on function public.my_news_email(), public.set_my_news_email(boolean), public.admin_announcements(), public.admin_send_announcement(text, text, text, text, boolean) from public, anon;
grant execute on function public.my_news_email(), public.set_my_news_email(boolean), public.admin_announcements(), public.admin_send_announcement(text, text, text, text, boolean) to authenticated;
revoke execute on function public.news_unsubscribe(text) from public;
grant execute on function public.news_unsubscribe(text) to anon, authenticated;
