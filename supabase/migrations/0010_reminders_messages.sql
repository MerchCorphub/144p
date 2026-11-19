-- 0010: daily member reminders (phone/desktop push and/or email) and leader messages to members.
-- Members turn reminders on in the app (off by default) and pick a time. Each day at that time in
-- their time zone they get "What will you give today?" with yesterday's minutes, their streak,
-- this week's chapter and their challenge standing. Church admins and group leaders can send short
-- messages to their church or group; members see them in the app and get them as a push or email.
-- Push messages are sent by the send-push function. Its VAPID key pair is stored in Supabase Vault as
-- 'vapid_public' and 'vapid_private' (added once by hand, never committed); the public key is also in cloud.js.

-- ---------- tables ----------
create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id) on delete cascade,
  endpoint text unique not null,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  failures int not null default 0
);
create index on public.push_subscriptions (partner_id);
alter table public.push_subscriptions enable row level security;
create policy push_own on public.push_subscriptions for select to authenticated using (partner_id = (select private.my_partner_id()));

create table public.push_outbox (
  id bigserial primary key,
  subscription_id uuid not null references public.push_subscriptions(id) on delete cascade,
  payload jsonb not null,
  kind text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0,
  last_error text
);
create index push_outbox_waiting on public.push_outbox (id) where sent_at is null;
alter table public.push_outbox enable row level security;

create table public.reminder_log (
  partner_id uuid not null references public.partners(id) on delete cascade,
  local_date date not null,
  sent_at timestamptz not null default now(),
  primary key (partner_id, local_date)
);
alter table public.reminder_log enable row level security;

create table public.member_messages (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references public.churches(id) on delete cascade,
  table_id uuid references public.tables(id) on delete set null,
  sender_partner_id uuid references public.partners(id) on delete set null,
  sender_name text not null,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now(),
  members int not null default 0,
  pushes int not null default 0,
  emails int not null default 0
);
create index on public.member_messages (church_id, created_at desc);
alter table public.member_messages enable row level security;

-- ---------- helpers ----------
create or replace function private.hm(m int) returns text language sql immutable as $$
  select case when coalesce(m, 0) >= 60 then (m / 60) || 'h ' || (m % 60) || 'm' else coalesce(m, 0) || 'm' end $$;

create or replace function private.local_now(tz text) returns timestamp
language plpgsql stable as $$
begin
  return now() at time zone coalesce(nullif(tz, ''), 'America/New_York');
exception when others then
  return now() at time zone 'America/New_York';
end $$;

create or replace function private.partner_name(pid uuid) returns text
language sql stable security definer set search_path = public as $$
  select first_name || coalesce(' ' || nullif(left(last_name, 1), '') || '.', '') from partners where id = pid $$;

-- Queue one push to every device a member turned reminders on for
create or replace function private.queue_push(pid uuid, payload jsonb, p_kind text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into push_outbox (subscription_id, payload, kind)
  select s.id, payload, p_kind from push_subscriptions s where s.partner_id = pid and s.failures < 5;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- the daily reminder ----------
create or replace function private.reminder_content(pid uuid, d date) returns json
language plpgsql stable security definer set search_path = public, private as $$
declare
  y int; streak int := 0; days date[]; s seasons; wk int; wtitle text; lines text[] := '{}'; short text[] := '{}';
  c challenges; side int; a_v numeric; b_v numeric; a_st record; b_st record; other text; rank int; total int;
begin
  select coalesce(sum(minutes), 0) into y from time_deposits where partner_id = pid and voided_at is null and activity_date = d - 1;
  select array_agg(distinct activity_date) into days from time_deposits
    where partner_id = pid and voided_at is null and minutes > 0 and activity_date between d - 400 and d - 1;
  while days is not null and (d - 1 - streak) = any(days) loop streak := streak + 1; end loop;

  lines := lines || ('Yesterday you gave God <strong>' || hm(y) || '</strong>' || case when y >= 144 then ' — a full tithe of your time. Well done!' else ' (the daily tithe is 2h 24m).' end);
  short := short || ('Yesterday: ' || hm(y));
  if streak >= 2 then lines := lines || ('You''re on a <strong>' || streak || '-day streak</strong>. Keep it going today.'); short := short || (streak || '-day streak'); end if;

  select * into s from seasons where active limit 1;
  if s.id is not null then
    if d < s.start_date then
      lines := lines || ('The Time4God Challenge begins in <strong>' || (s.start_date - d) || ' day' || case when s.start_date - d = 1 then '' else 's' end || '</strong> (' || to_char(s.start_date, 'FMMonth FMDD') || ').');
    elsif d <= s.start_date + 83 then
      wk := ((d - s.start_date) / 7) + 1;
      select title into wtitle from book_sections where kind = 'week' and unlock_week = wk and not hidden limit 1;
      if wtitle is not null then lines := lines || ('This week: <strong>' || h(wtitle) || '</strong>.'); short := short || split_part(wtitle, ' · ', 1); end if;
    end if;
  end if;

  select ch.* into c from challenges ch
  where ch.status = 'active' and d between ch.start_date and ch.end_date
    and (pid in (select private.challenge_members(ch, 1)) or pid in (select private.challenge_members(ch, 2)))
  order by ch.end_date limit 1;
  if c.id is not null then
    if c.kind = 'church_open' then
      select count(*), coalesce(sum(case when t.total > me.total then 1 else 0 end), 0) + 1 into total, rank
      from (select e.partner_id, coalesce((select sum(dd.minutes) from time_deposits dd where dd.partner_id = e.partner_id and dd.voided_at is null and dd.activity_date between c.start_date and least(c.end_date, d)), 0) total
            from challenge_entrants e where e.challenge_id = c.id) t,
           (select coalesce(sum(dd.minutes), 0) total from time_deposits dd where dd.partner_id = pid and dd.voided_at is null and dd.activity_date between c.start_date and least(c.end_date, d)) me;
      lines := lines || ('In <strong>' || h(coalesce(c.title, 'your church challenge')) || '</strong> you''re <strong>#' || rank || ' of ' || total || '</strong>.');
      short := short || ('#' || rank || ' of ' || total);
    else
      side := case when pid in (select private.challenge_members(c, 1)) then 1 else 2 end;
      select * into a_st from private.challenge_stats(c, 1);
      select * into b_st from private.challenge_stats(c, 2);
      a_v := case when c.kind = 'person' then a_st.total else a_st.total::numeric / nullif(a_st.members, 0) end;
      b_v := case when c.kind = 'person' then b_st.total else b_st.total::numeric / nullif(b_st.members, 0) end;
      other := private.challenge_side_name(c, case when side = 1 then 2 else 1 end);
      if coalesce(a_v, 0) = coalesce(b_v, 0) then
        lines := lines || ('Your challenge with <strong>' || h(other) || '</strong> is tied. Today can make the difference.');
        short := short || ('Tied with ' || other);
      elsif (side = 1 and a_v > coalesce(b_v, 0)) or (side = 2 and b_v > coalesce(a_v, 0)) then
        lines := lines || ('You''re <strong>ahead</strong> of ' || h(other) || ' by ' || hm(abs(round(coalesce(a_v, 0) - coalesce(b_v, 0)))::int) || case when c.kind = 'person' then '' else ' per member' end || '. Keep it up!');
        short := short || ('Ahead of ' || other);
      else
        lines := lines || ('You''re <strong>behind</strong> ' || h(other) || ' by ' || hm(abs(round(coalesce(a_v, 0) - coalesce(b_v, 0)))::int) || case when c.kind = 'person' then '' else ' per member' end || '. Today is a good day to catch up.');
        short := short || ('Behind ' || other);
      end if;
    end if;
  end if;

  return json_build_object('title', 'What will you give today?', 'lines', to_json(lines), 'short', array_to_string(short, ' · '));
end $$;

create or replace function private.queue_daily_reminders() returns int
language plpgsql security definer set search_path = public, private as $$
declare r record; lt timestamp; ld date; tm time; content json; n int := 0; em text;
begin
  for r in select np.*, p.timezone as ptz, p.first_name, p.email as pemail
           from notification_preferences np join partners p on p.id = np.partner_id
           where np.reminder_enabled or np.email_reminder loop
    lt := private.local_now(coalesce(r.timezone, r.ptz));
    ld := lt::date; tm := coalesce(r.reminder_time, '07:00');
    if lt::time < tm or lt::time >= tm + interval '30 minutes' then continue; end if;
    insert into reminder_log (partner_id, local_date) values (r.partner_id, ld) on conflict do nothing;
    if not found then continue; end if;
    content := private.reminder_content(r.partner_id, ld);
    if r.reminder_enabled then
      perform private.queue_push(r.partner_id, jsonb_build_object('title', content->>'title', 'body', coalesce(nullif(content->>'short', ''), 'Open the app and log your time.'),
        'url', 'https://time4god.app/', 'tag', 'daily-reminder'), 'reminder');
    end if;
    if r.email_reminder then
      select u.email into em from auth.users u join partners p on p.auth_user_id = u.id where p.id = r.partner_id;
      perform private.queue_email(coalesce(em, r.pemail), 'What will you give today, ' || r.first_name || '?',
        (select array_agg(x) from json_array_elements_text(content->'lines') x),
        'Log my time', 'https://time4god.app/',
        'You asked for a daily reminder. To change the time or turn it off, open the app › Reminders.', 'member.reminder');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- devices ----------
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns void language plpgsql security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id();
begin
  if pid is null then raise exception 'Create your account first.'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or length(p_p256dh) > 200 or length(p_auth) > 100 then raise exception 'That device can''t receive notifications.'; end if;
  insert into push_subscriptions (partner_id, endpoint, p256dh, auth, user_agent)
  values (pid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update set partner_id = pid, p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent, failures = 0;
end $$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = public, private as $$
  delete from push_subscriptions where endpoint = p_endpoint and partner_id = private.my_partner_id() $$;

-- ---------- leader messages ----------
create or replace function public.send_member_message(cid uuid, p_group uuid, p_body text)
returns json language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); boss boolean := private.manages_church(cid); t tables; body text := trim(p_body);
  mid uuid; n_mem int := 0; n_push int := 0; n_mail int := 0; r record; cname text; sname text; pushn int;
begin
  if not private.can_approve(cid) then raise exception 'Only leaders of this church can send messages.'; end if;
  if body is null or body = '' then raise exception 'Write a message first.'; end if;
  if char_length(body) > 500 then raise exception 'Keep messages under 500 characters.'; end if;
  if p_group is not null then
    select * into t from tables where id = p_group and church_id = cid and status = 'active';
    if t.id is null then raise exception 'That group was not found.'; end if;
    if not boss and t.leader_partner_id is distinct from me then raise exception 'You can only message the group you lead.'; end if;
  elsif not boss then
    raise exception 'Only the church admin can message the whole church. Choose your group.';
  end if;
  if (select count(*) from member_messages where church_id = cid and created_at > now() - interval '1 day') >= 5 then
    raise exception 'This church has sent 5 messages in the last 24 hours. Please wait before sending more.';
  end if;
  select name into cname from churches where id = cid;
  sname := coalesce(private.partner_name(me), 'Your church');
  insert into member_messages (church_id, table_id, sender_partner_id, sender_name, body)
  values (cid, p_group, me, sname, body) returning id into mid;
  for r in select m.partner_id, np.reminder_enabled, np.email_reminder, p.email, p.first_name
           from memberships m join partners p on p.id = m.partner_id
           left join notification_preferences np on np.partner_id = m.partner_id
           where m.church_id = cid and m.status = 'verified' and (p_group is null or m.table_id = p_group) and m.partner_id <> coalesce(me, '00000000-0000-0000-0000-000000000000') loop
    n_mem := n_mem + 1;
    pushn := 0;
    if coalesce(r.reminder_enabled, false) then
      pushn := private.queue_push(r.partner_id, jsonb_build_object('title', coalesce(t.name, cname), 'body', left(body, 180),
        'url', 'https://time4god.app/challenges.html#messages', 'tag', 'msg-' || mid), 'message');
      n_push := n_push + pushn;
    end if;
    if coalesce(r.email_reminder, false) then
      perform private.queue_email(r.email, 'Message from ' || coalesce(t.name || ' · ', '') || cname,
        array['<strong>' || h(sname) || '</strong> sent a message to ' || h(coalesce(t.name, cname)) || ':', '“' || h(body) || '”'],
        'Open the app', 'https://time4god.app/challenges.html#messages',
        'You get this because you turned on email reminders. To stop them, open the app › Reminders.', 'member.message');
      n_mail := n_mail + 1;
    end if;
  end loop;
  update member_messages set members = n_mem, pushes = n_push, emails = n_mail where id = mid;
  return json_build_object('members', n_mem, 'pushes', n_push, 'emails', n_mail);
end $$;

create or replace function public.leader_messages(cid uuid)
returns table (id uuid, created_at timestamptz, sender_name text, group_name text, body text, members int, pushes int, emails int)
language sql stable security definer set search_path = public, private as $$
  select m.id, m.created_at, m.sender_name, t.name, m.body, m.members, m.pushes, m.emails
  from member_messages m left join tables t on t.id = m.table_id
  where m.church_id = cid and private.can_approve(cid)
  order by m.created_at desc limit 30 $$;

create or replace function public.my_messages()
returns table (id uuid, created_at timestamptz, church_name text, group_name text, sender_name text, body text)
language sql stable security definer set search_path = public, private as $$
  select m.id, m.created_at, c.name, t.name, m.sender_name, m.body
  from memberships ms join member_messages m on m.church_id = ms.church_id
  join churches c on c.id = m.church_id left join tables t on t.id = m.table_id
  where ms.partner_id = private.my_partner_id() and ms.status = 'verified'
    and (m.table_id is null or m.table_id = ms.table_id) and m.created_at > now() - interval '30 days'
  order by m.created_at desc limit 10 $$;

-- ---------- service-role helpers for send-push ----------
create or replace function public.push_keys() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('public', (select decrypted_secret from vault.decrypted_secrets where name = 'vapid_public'),
                           'private', (select decrypted_secret from vault.decrypted_secrets where name = 'vapid_private')) $$;

create or replace function private.wake_push_sender() returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from push_outbox where sent_at is null and attempts < 3) then
    perform net.http_post(
      url := 'https://hevkjegnogadwybbmwjx.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object('Content-Type', 'application/json',
                   'x-notify-token', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_token')),
      body := '{}'::jsonb, timeout_milliseconds := 60000);
  end if;
end $$;

-- ---------- grants ----------
do $$ declare f text; begin
  foreach f in array array['save_push_subscription(text, text, text, text)', 'delete_push_subscription(text)', 'send_member_message(uuid, uuid, text)', 'leader_messages(uuid)', 'my_messages()']
  loop execute format('revoke execute on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
revoke execute on function public.push_keys() from public, anon, authenticated;
grant execute on function public.push_keys() to service_role;
revoke execute on function private.queue_push(uuid, jsonb, text), private.reminder_content(uuid, date), private.queue_daily_reminders(), private.wake_push_sender() from public, anon, authenticated;

-- ---------- schedules ----------
select cron.schedule('daily-reminders', '*/5 * * * *', 'select private.queue_daily_reminders(); select private.wake_push_sender(); select private.wake_email_sender();');
select cron.schedule('send-push', '* * * * *', 'select private.wake_push_sender()');
