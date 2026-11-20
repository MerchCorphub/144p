-- 0015: Admin Panel dashboard. One call returns the operating overview for the platform admin:
-- members, churches and groups, engagement, challenges, study-book access, and revenue
-- (Stripe live vs test kept apart; amounts are gross, before Stripe fees).
create or replace function public.admin_dashboard() returns json
language plpgsql stable security definer set search_path = public, private as $$
declare s seasons; r json;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see the dashboard.'; end if;
  select * into s from seasons where active limit 1;
  with live as (select * from payments where status = 'paid' and coalesce(stripe_session_id, '') not like 'cs_test_%'),
       test as (select * from payments where status = 'paid' and stripe_session_id like 'cs_test_%'),
       dep as (select partner_id, activity_date, sum(minutes) m from time_deposits where voided_at is null group by 1, 2),
       lic as (select l.* from churches c cross join lateral (select * from private.current_church_license(c.id)) l where c.status = 'active' and l.id is not null)
  select json_build_object(
    'as_of', now(),
    'season', json_build_object('name', s.name, 'start', s.start_date, 'days_to_start', s.start_date - current_date,
                                'week', case when current_date >= s.start_date then least(12, (current_date - s.start_date) / 7 + 1) end),
    'members', json_build_object(
      'accounts', (select count(*) from partners),
      'new_7', (select count(*) from partners where created_at > now() - interval '7 days'),
      'new_30', (select count(*) from partners where created_at > now() - interval '30 days'),
      'in_church', (select count(*) from memberships where status = 'verified'),
      'pending', (select count(*) from memberships where status = 'pending'),
      'no_church', (select count(*) from partners p where not exists (select 1 from memberships m where m.partner_id = p.id and m.status in ('pending', 'verified'))),
      'with_book', (select count(distinct p.id) from partners p where private.has_individual_seat(p.id)
                      or exists (select 1 from memberships m where m.partner_id = p.id and m.status = 'verified' and (private.current_church_license(m.church_id)).status = 'active')),
      'own_seats', (select count(*) from individual_seats i where i.status = 'active'),
      'key_claims', (select count(*) from key_claims),
      'signups_by_week', (select coalesce(json_agg(json_build_object('week', w, 'n', n) order by w), '[]'::json) from (
          select g::date w, (select count(*) from partners p where p.created_at >= g and p.created_at < g + interval '7 days') n
          from generate_series(date_trunc('week', now()) - interval '11 weeks', date_trunc('week', now()), interval '7 days') g) x)),
    'engagement', json_build_object(
      'active_7', (select count(distinct partner_id) from dep where activity_date > current_date - 7),
      'minutes_7', (select coalesce(sum(m), 0) from dep where activity_date > current_date - 7),
      'minutes_all', (select coalesce(sum(m), 0) from dep),
      'days_at_144_7', (select count(*) from dep where activity_date > current_date - 7 and m >= 144),
      'reminders_push', (select count(*) from notification_preferences where reminder_enabled),
      'reminders_email', (select count(*) from notification_preferences where email_reminder),
      'devices', (select count(*) from push_subscriptions),
      'minutes_by_day', (select coalesce(json_agg(json_build_object('day', d, 'm', coalesce((select sum(m) from dep where activity_date = d), 0)) order by d), '[]'::json)
                         from generate_series(current_date - 13, current_date, interval '1 day') d)),
    'churches', json_build_object(
      'active', (select count(*) from churches where status = 'active' and kind = 'church'),
      'groups_independent', (select count(*) from churches where status = 'active' and kind = 'group'),
      'requests', (select count(*) from churches where status = 'pending'),
      'groups_inside', (select count(*) from tables where status = 'active'),
      'leader_requests', (select count(*) from group_lead_requests where status = 'pending'),
      'licensed', (select count(*) from lic where status = 'active'),
      'seats_sold', (select coalesce(sum(seats), 0) from lic where status = 'active'),
      'seats_used', (select count(*) from memberships m where m.status = 'verified' and exists (select 1 from lic where lic.church_id = m.church_id and lic.status = 'active')),
      'top', (select coalesce(json_agg(t), '[]'::json) from (
          select c.name, (select count(*) from memberships m where m.church_id = c.id and m.status = 'verified') members,
                 (select count(*) from memberships m where m.church_id = c.id and m.status = 'pending') pending,
                 l.seats, coalesce((select sum(d.m) from dep d join memberships m on m.partner_id = d.partner_id and m.church_id = c.id and m.status = 'verified' where d.activity_date > current_date - 7), 0) minutes_7
          from churches c left join lic l on l.church_id = c.id where c.status = 'active' order by 2 desc, 1 limit 8) t)),
    'challenges', json_build_object(
      'live', (select count(*) from challenges where status = 'active' and current_date between start_date and end_date),
      'upcoming', (select count(*) from challenges where status = 'active' and current_date < start_date),
      'waiting', (select count(*) from challenges where status = 'pending'),
      'finished', (select count(*) from challenges where status = 'active' and current_date > end_date)),
    'revenue', json_build_object(
      'total', (select coalesce(sum(amount), 0) from live),
      'month', (select coalesce(sum(amount), 0) from live where paid_at >= date_trunc('month', now())),
      'last_30', (select coalesce(sum(amount), 0) from live where paid_at > now() - interval '30 days'),
      'payments', (select count(*) from live),
      'individual', (select coalesce(sum(amount), 0) from live where kind = 'individual'),
      'church', (select coalesce(sum(amount), 0) from live where kind = 'church_new'),
      'upgrades', (select coalesce(sum(amount), 0) from live where kind = 'church_upgrade'),
      'abandoned_30', (select count(*) from payments where status in ('open', 'expired') and created_at > now() - interval '30 days'),
      'test_total', (select coalesce(sum(amount), 0) from test),
      'test_payments', (select count(*) from test),
      'renewals_60', (select count(*) from church_licenses where status = 'active' and expires_at between now() and now() + interval '60 days')
                     + (select count(*) from individual_seats where status = 'active' and expires_at between now() and now() + interval '60 days'),
      'by_month', (select coalesce(json_agg(json_build_object('month', mth, 'amount', coalesce((select sum(amount) from live where date_trunc('month', paid_at) = mth), 0)) order by mth), '[]'::json)
                   from generate_series(date_trunc('month', now()) - interval '11 months', date_trunc('month', now()), interval '1 month') mth),
      'recent', (select coalesce(json_agg(x), '[]'::json) from (select paid_at, description, amount, stripe_session_id like 'cs_test_%' as test from payments where status = 'paid' order by paid_at desc limit 6) x))
  ) into r;
  return r;
end $$;
revoke execute on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;
