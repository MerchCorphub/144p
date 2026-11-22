-- 0028: trial passes can be sent by text message from the admin's phone. The app makes the
-- invitation link; the admin's own Messages app sends it. (Text invites store an empty email.)
alter table public.trial_invites add column if not exists via text not null default 'email' check (via in ('email', 'text'));

create or replace function public.admin_create_trial_link(p_name text default null, p_note text default null, p_days int default 14) returns json
language plpgsql security definer set search_path = public, private as $$
declare t trial_invites;
begin
  if not private.is_platform_admin() then raise exception 'Only an admin can send trial passes.'; end if;
  if coalesce(p_days, 14) not between 1 and 60 then raise exception 'Choose 1 to 60 days.'; end if;
  insert into trial_invites (code, email, name, note, days, created_by, via)
  values (upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)), '', nullif(trim(p_name), ''), nullif(trim(p_note), ''), coalesce(p_days, 14), auth.uid(), 'text')
  returning * into t;
  return json_build_object('id', t.id, 'code', t.code, 'url', 'https://time4god.app/access.html?trial=' || t.code, 'expires_at', t.expires_at);
end $$;

-- "Text again": another 30 days on an unused text invitation, and its link
create or replace function public.admin_trial_text_again(p_id uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare t trial_invites;
begin
  if not private.is_platform_admin() then raise exception 'Only an admin can resend trial passes.'; end if;
  update trial_invites set expires_at = greatest(expires_at, now() + interval '30 days') where id = p_id and claimed_by is null and canceled_at is null returning * into t;
  if t.id is null then raise exception 'Only an unused invitation can be sent again.'; end if;
  return json_build_object('url', 'https://time4god.app/access.html?trial=' || t.code, 'name', t.name, 'note', t.note, 'days', t.days);
end $$;

-- Email invitations: the custom message goes in place of the standard opening
create or replace function private.trial_email(t trial_invites) returns void
language plpgsql security definer set search_path = public, private as $$
declare free text := case when t.days % 7 = 0 then (t.days / 7) || case when t.days = 7 then ' week' else ' weeks' end else t.days || ' days' end;
begin
  if coalesce(t.email, '') = '' then return; end if;
  perform private.queue_email(t.email, 'You’re invited: ' || free || ' free in the Time4God Challenge',
    case when t.note is not null then
      array[replace(h(t.note), E'\n', '<br>'), 'Your free ' || free || ' start when you accept. This invitation is good until ' || to_char(t.expires_at, 'FMMonth FMDD') || '.']
    else
      array[case when t.name is not null then 'Hi ' || h(t.name) || ',' else 'Hello,' end,
            'You’re invited to try the 144(P) Plan app free for ' || free || '. Read the 12-week study book <em>What Will You Give Today?</em>, log your time with God, and take the Time4God Challenge.',
            'Your free ' || free || ' start when you accept. This invitation is good until ' || to_char(t.expires_at, 'FMMonth FMDD') || '.'] end,
    'Start my free ' || free, 'https://time4god.app/access.html?trial=' || t.code, null, 'member.trial_invite');
end $$;

create or replace function public.admin_trials_v2()
returns table (id uuid, email text, name text, days int, created_at timestamptz, expires_at timestamptz, claimed_at timestamptz, trial_until date,
               canceled_at timestamptz, reader text, reader_email text, status text, joined boolean, code text, via text, note text)
language sql stable security definer set search_path = public, private as $$
  select t.id, nullif(t.email, ''), t.name, t.days, t.created_at, t.expires_at, t.claimed_at, t.trial_until, t.canceled_at,
    trim(p.first_name || ' ' || p.last_name), p.email,
    case when t.canceled_at is not null then 'canceled'
         when t.claimed_by is null and t.expires_at < now() then 'expired'
         when t.claimed_by is null then 'sent'
         when private.paid_access(t.claimed_by) then 'joined'
         when t.trial_until >= current_date then 'active'
         else 'ended' end,
    t.claimed_by is not null and private.paid_access(t.claimed_by), t.code, t.via, t.note
  from trial_invites t left join partners p on p.id = t.claimed_by
  where private.is_platform_admin() order by t.created_at desc $$;

revoke execute on function private.trial_email(trial_invites) from public, anon, authenticated;
revoke execute on function public.admin_create_trial_link(text, text, int), public.admin_trial_text_again(uuid), public.admin_trials_v2() from public, anon;
grant execute on function public.admin_create_trial_link(text, text, int), public.admin_trial_text_again(uuid), public.admin_trials_v2() to authenticated;
