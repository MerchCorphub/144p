-- 0027: trial passes. Admins send invitations by email; the person who accepts gets the full
-- study book free for 14 days from the day they accept, then is asked to join at the current
-- individual price. Unused invitations expire after 30 days. One trial per person.
-- New member category "trial" (Member > Guest > Trial > Prospect).
create table if not exists public.trial_invites (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  email text not null,
  name text,
  note text,
  days int not null default 14 check (days between 1 and 60),
  created_by uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  claimed_by uuid references public.partners(id) on delete set null,
  claimed_at timestamptz,
  trial_until date,
  canceled_at timestamptz,
  reminded_at timestamptz,
  ended_notice_at timestamptz
);
create index if not exists trial_invites_claimed on public.trial_invites (claimed_by);
alter table public.trial_invites enable row level security;
revoke all on public.trial_invites from anon, authenticated;

create or replace function private.trial_until(pid uuid) returns date
language sql stable security definer set search_path = public as $$
  select max(trial_until) from trial_invites where claimed_by = pid and canceled_at is null $$;

create or replace function private.member_category(pid uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select case when private.paid_access(pid) then 'member'
              when coalesce(private.guest_until(pid) >= current_date, false) then 'guest'
              when coalesce(private.trial_until(pid) >= current_date, false) then 'trial'
              else 'prospect' end $$;

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
        or coalesce(private.guest_until(pid) >= current_date, false)
        or coalesce(private.trial_until(pid) >= current_date, false)
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

create or replace function private.trial_email(t trial_invites) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.queue_email(t.email, 'You’re invited: 2 weeks free in the Time4God Challenge',
    array[case when t.name is not null then 'Hi ' || h(t.name) || ',' else 'Hello,' end,
          'You’re invited to try the 144(P) Plan app free for ' || t.days || ' days. Read the 12-week study book <em>What Will You Give Today?</em>, log your time with God, and take the Time4God Challenge.',
          coalesce(h(t.note), ''),
          'Your free days start when you accept. This invitation is good until ' || to_char(t.expires_at, 'FMMonth FMDD') || '.'],
    'Start my free ' || t.days || ' days', 'https://time4god.app/access.html?trial=' || t.code, null, 'member.trial_invite');
end $$;

create or replace function public.admin_create_trials(p_emails text, p_name text default null, p_note text default null, p_days int default 14) returns int
language plpgsql security definer set search_path = public, private as $$
declare e text; n int := 0; t trial_invites;
begin
  if not private.is_platform_admin() then raise exception 'Only an admin can send trial passes.'; end if;
  if coalesce(p_days, 14) not between 1 and 60 then raise exception 'Choose 1 to 60 days.'; end if;
  for e in select distinct lower(trim(x)) from regexp_split_to_table(coalesce(p_emails, ''), '[,;\s]+') x where trim(x) <> '' loop
    if not private.valid_email(e) then raise exception '"%" doesn''t look like an email address.', e; end if;
  end loop;
  for e in select distinct lower(trim(x)) from regexp_split_to_table(coalesce(p_emails, ''), '[,;\s]+') x where trim(x) <> '' loop
    insert into trial_invites (code, email, name, note, days, created_by)
    values (upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)), e, nullif(trim(p_name), ''), nullif(trim(p_note), ''), coalesce(p_days, 14), auth.uid())
    returning * into t;
    perform private.trial_email(t);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Enter at least one email address.'; end if;
  return n;
end $$;

create or replace function public.admin_trials()
returns table (id uuid, email text, name text, days int, created_at timestamptz, expires_at timestamptz, claimed_at timestamptz, trial_until date,
               canceled_at timestamptz, reader text, reader_email text, status text, joined boolean, code text)
language sql stable security definer set search_path = public, private as $$
  select t.id, t.email, t.name, t.days, t.created_at, t.expires_at, t.claimed_at, t.trial_until, t.canceled_at,
    trim(p.first_name || ' ' || p.last_name), p.email,
    case when t.canceled_at is not null then 'canceled'
         when t.claimed_by is null and t.expires_at < now() then 'expired'
         when t.claimed_by is null then 'sent'
         when private.paid_access(t.claimed_by) then 'joined'
         when t.trial_until >= current_date then 'active'
         else 'ended' end,
    t.claimed_by is not null and private.paid_access(t.claimed_by), t.code
  from trial_invites t left join partners p on p.id = t.claimed_by
  where private.is_platform_admin() order by t.created_at desc $$;

create or replace function public.admin_cancel_trial(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only an admin can cancel trial passes.'; end if;
  update trial_invites set canceled_at = now() where id = p_id and canceled_at is null;
end $$;

create or replace function public.admin_resend_trial(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare t trial_invites;
begin
  if not private.is_platform_admin() then raise exception 'Only an admin can resend trial passes.'; end if;
  update trial_invites set expires_at = greatest(expires_at, now() + interval '30 days') where id = p_id and claimed_by is null and canceled_at is null returning * into t;
  if t.id is null then raise exception 'Only an unused invitation can be sent again.'; end if;
  perform private.trial_email(t);
end $$;

-- What the invitation link shows (before or after sign-in)
create or replace function public.trial_preview(p_code text) returns json
language plpgsql stable security definer set search_path = public, private as $$
declare t trial_invites; me uuid := private.my_partner_id();
begin
  select * into t from trial_invites where code = upper(trim(p_code));
  if t.id is null then return json_build_object('ok', false, 'reason', 'This invitation link isn’t valid.'); end if;
  if t.canceled_at is not null then return json_build_object('ok', false, 'reason', 'This invitation was canceled.'); end if;
  if t.claimed_by is not null then return json_build_object('ok', t.claimed_by = me, 'mine', t.claimed_by = me, 'claimed', true, 'trial_until', case when t.claimed_by = me then t.trial_until end,
    'reason', case when t.claimed_by = me then null else 'This invitation has already been used.' end); end if;
  if t.expires_at < now() then return json_build_object('ok', false, 'reason', 'This invitation has expired.'); end if;
  return json_build_object('ok', true, 'days', t.days, 'name', t.name, 'expires_at', t.expires_at);
end $$;

create or replace function public.trial_claim(p_code text) returns json
language plpgsql security definer set search_path = public, private as $$
declare t trial_invites; me uuid := private.my_partner_id();
begin
  if me is null then raise exception 'Create your account first.'; end if;
  select * into t from trial_invites where code = upper(trim(p_code)) for update;
  if t.id is null then raise exception 'This invitation link isn’t valid.'; end if;
  if t.claimed_by = me then return json_build_object('status', 'already', 'trial_until', t.trial_until); end if;
  if t.canceled_at is not null then raise exception 'This invitation was canceled.'; end if;
  if t.claimed_by is not null then raise exception 'This invitation has already been used.'; end if;
  if t.expires_at < now() then raise exception 'This invitation has expired.'; end if;
  if private.paid_access(me) then raise exception 'You already have the study book. Open the app to start reading.'; end if;
  if exists (select 1 from trial_invites where claimed_by = me) then raise exception 'You’ve already had a free trial. Join to keep reading.'; end if;
  update trial_invites set claimed_by = me, claimed_at = now(), trial_until = current_date + t.days where id = t.id returning * into t;
  insert into audit_logs (actor_id, action, resource_type, resource_id) values (auth.uid(), 'trial.claimed', 'trial_invite', t.id::text);
  return json_build_object('status', 'ok', 'trial_until', t.trial_until);
end $$;

-- Reminder 2 days before the trial ends, and a note the day after it ends (daily)
create or replace function private.queue_trial_reminders() returns int
language plpgsql security definer set search_path = public, private as $$
declare t record; n int := 0; price numeric := (select price from license_plans where kind = 'individual' and active order by sort_order limit 1);
begin
  for t in select ti.*, p.email pe, p.first_name fn from trial_invites ti join partners p on p.id = ti.claimed_by
           where ti.canceled_at is null and ti.reminded_at is null and ti.trial_until = current_date + 2 and not private.paid_access(ti.claimed_by) loop
    perform private.queue_email(t.pe, 'Your free trial ends in 2 days',
      array['Hi ' || h(t.fn) || ', your free days in the 144(P) Plan app end on ' || to_char(t.trial_until, 'FMMonth FMDD') || '.',
            'Keep reading <em>What Will You Give Today?</em> and keep your time with God going: join for $' || to_char(price, 'FM999,990.00') || ' for a full year. Your purchase includes a seat to give someone you challenge.'],
      'Join for $' || to_char(price, 'FM999,990.00'), 'https://time4god.app/access.html', null, 'member.trial_ending');
    update trial_invites set reminded_at = now() where id = t.id; n := n + 1;
  end loop;
  for t in select ti.*, p.email pe, p.first_name fn from trial_invites ti join partners p on p.id = ti.claimed_by
           where ti.canceled_at is null and ti.ended_notice_at is null and ti.trial_until < current_date and ti.trial_until >= current_date - 7 and not private.paid_access(ti.claimed_by) loop
    perform private.queue_email(t.pe, 'Your free trial has ended',
      array['Hi ' || h(t.fn) || ', thank you for spending these days with us.',
            'Your free trial ended on ' || to_char(t.trial_until, 'FMMonth FMDD') || '. Join for $' || to_char(price, 'FM999,990.00') || ' to open the study book again for a full year. Your time with God so far is saved.'],
      'Join for $' || to_char(price, 'FM999,990.00'), 'https://time4god.app/access.html', null, 'member.trial_ended');
    update trial_invites set ended_notice_at = now() where id = t.id; n := n + 1;
  end loop;
  return n;
end $$;
select cron.schedule('trial-reminders', '7 14 * * *', 'select private.queue_trial_reminders()');

-- my_access, All members, No church and Dashboard learn about trials
create or replace function public.my_access() returns json
language plpgsql stable security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); m record; seat record; g record; gu date; tu date;
begin
  select ms.status, c.name, (private.current_church_license(ms.church_id)).status as lic into m
  from memberships ms join churches c on c.id = ms.church_id where ms.partner_id = pid and ms.status in ('pending', 'verified') limit 1;
  select i.expires_at, i.price into seat from individual_seats i, seasons s
  where s.active and i.partner_id = pid and i.status = 'active' and private.license_covers(i.season_id, i.expires_at, s)
  order by i.expires_at desc nulls last limit 1;
  gu := private.guest_until(pid); tu := private.trial_until(pid);
  select (select first_name from partners where id = gp.owner_partner_id) as giver into g
  from guest_passes gp where gp.claimed_by = pid order by gp.access_until desc limit 1;
  return json_build_object('church', m.name, 'church_status', m.status, 'church_license', m.lic,
    'church_covers', m.status = 'verified' and m.lic = 'active',
    'seat', seat.expires_at is not null or seat.price is not null, 'seat_expires', seat.expires_at,
    'guest_until', gu, 'guest_active', coalesce(gu >= current_date, false), 'guest_from', g.giver,
    'trial_until', tu, 'trial_active', coalesce(tu >= current_date, false),
    'keep_going_price', private.keep_going_price(pid),
    'individual_price', (select price from license_plans where kind = 'individual' and active order by sort_order limit 1),
    'guest_seats_left', private.guest_seats_left(pid),
    'guest_seat_given_to', (select p.first_name from guest_passes gp join partners p on p.id = gp.claimed_by
                            where gp.owner_partner_id = pid order by gp.claimed_at desc limit 1),
    'category', case when pid is null then null else private.member_category(pid) end,
    'paid_by', case when pid is null then null else private.member_paid_by(pid) end,
    'admin', private.is_platform_admin());
end $$;

drop function if exists public.admin_all_members();
create function public.admin_all_members()
returns table (partner_id uuid, name text, email text, created_at timestamptz, category text, paid_by text, guest_until date, guest_from text,
               church text, church_status text, minutes_all bigint, minutes_30 bigint, last_active date, trial_until date)
language sql stable security definer set search_path = public, private as $$
  select p.id, trim(p.first_name || ' ' || p.last_name), p.email, p.created_at,
    private.member_category(p.id), private.member_paid_by(p.id), private.guest_until(p.id),
    (select o.first_name from guest_passes gp join partners o on o.id = gp.owner_partner_id where gp.claimed_by = p.id order by gp.access_until desc limit 1),
    (select c.name from memberships m join churches c on c.id = m.church_id where m.partner_id = p.id and m.status in ('pending', 'verified') limit 1),
    (select m.status from memberships m where m.partner_id = p.id and m.status in ('pending', 'verified') limit 1),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d where d.partner_id = p.id and d.voided_at is null),
    (select coalesce(sum(d.minutes), 0)::bigint from time_deposits d where d.partner_id = p.id and d.voided_at is null and d.activity_date > current_date - 30),
    (select max(d.activity_date) from time_deposits d where d.partner_id = p.id and d.voided_at is null),
    private.trial_until(p.id)
  from partners p where private.is_platform_admin() order by p.created_at desc $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.admin_dashboard()'::regprocedure);
  d := replace(d, $q$'guest', count(*) filter (where c = 'guest'),$q$, $q$'guest', count(*) filter (where c = 'guest'), 'trial', count(*) filter (where c = 'trial'),$q$);
  if position($q$'trial', count(*)$q$ in d) = 0 then raise exception 'dashboard not updated'; end if;
  execute d;
end $$;

revoke execute on function private.trial_until(uuid), private.trial_email(trial_invites), private.queue_trial_reminders() from public, anon, authenticated;
grant execute on function private.trial_until(uuid) to authenticated;
revoke execute on function public.admin_create_trials(text, text, text, int), public.admin_trials(), public.admin_cancel_trial(uuid), public.admin_resend_trial(uuid),
  public.trial_claim(text), public.admin_all_members(), public.my_access() from public, anon;
grant execute on function public.admin_create_trials(text, text, text, int), public.admin_trials(), public.admin_cancel_trial(uuid), public.admin_resend_trial(uuid),
  public.trial_claim(text), public.admin_all_members(), public.my_access() to authenticated;
revoke execute on function public.trial_preview(text) from public;
grant execute on function public.trial_preview(text) to anon, authenticated;

-- 0027b (applied separately): subject and wording follow the number of days ("2 weeks", "10 days")
create or replace function private.trial_email(t trial_invites) returns void
language plpgsql security definer set search_path = public, private as $$
declare free text := case when t.days % 7 = 0 then (t.days / 7) || case when t.days = 7 then ' week' else ' weeks' end else t.days || ' days' end;
begin
  perform private.queue_email(t.email, 'You’re invited: ' || free || ' free in the Time4God Challenge',
    array[case when t.name is not null then 'Hi ' || h(t.name) || ',' else 'Hello,' end,
          'You’re invited to try the 144(P) Plan app free for ' || free || '. Read the 12-week study book <em>What Will You Give Today?</em>, log your time with God, and take the Time4God Challenge.',
          coalesce(h(t.note), ''),
          'Your free ' || free || ' start when you accept. This invitation is good until ' || to_char(t.expires_at, 'FMMonth FMDD') || '.'],
    'Start my free ' || free, 'https://time4god.app/access.html?trial=' || t.code, null, 'member.trial_invite');
end $$;
revoke execute on function private.trial_email(trial_invites) from public, anon, authenticated;
