-- 0036: Challenge a member by phone number.
--  * Members may add an optional phone number in My Account. It is used only so other members can find them
--    for a challenge. It is never shown to other members and the app does not send text messages.
--  * "Challenge a member by phone": if the number matches exactly one member, a person challenge is created for
--    that member only. It shows on their Challenges page and they get an email. The sender never sees whose number it is.
--  * If no member matches, nothing is created and the sender can text the link from their own phone instead.
--  * Lookups are limited to 20 a day per member.

alter table public.partners add column if not exists phone text;
alter table public.partners add column if not exists phone_norm text;
create index if not exists partners_phone_norm on public.partners (phone_norm) where phone_norm is not null;
alter table public.challenges add column if not exists target_partner_id uuid references public.partners(id) on delete set null;

create table if not exists public.phone_lookups (id bigserial primary key, partner_id uuid not null, at timestamptz not null default now(), matched boolean);
alter table public.phone_lookups enable row level security;
revoke all on public.phone_lookups from anon, authenticated;

-- Digits only; US 10-digit numbers get a leading 1
create or replace function private.norm_phone(t text) returns text
language sql immutable as $$
  select case when d ~ '^[0-9]{10}$' then '1' || d when d ~ '^1[0-9]{10}$' then d when length(d) between 8 and 15 then d end
  from (select regexp_replace(coalesce(t, ''), '[^0-9]', '', 'g') as d) x $$;

create or replace function public.my_phone() returns text
language sql stable security definer set search_path = public, private as $$ select phone from partners where id = private.my_partner_id() $$;

create or replace function public.set_my_phone(p_phone text) returns text
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); n text := private.norm_phone(p_phone);
begin
  if me is null then raise exception 'Please sign in again.'; end if;
  if nullif(trim(coalesce(p_phone, '')), '') is null then update partners set phone = null, phone_norm = null where id = me; return null; end if;
  if n is null then raise exception 'Check the phone number. Use your full number with area code.'; end if;
  update partners set phone = trim(p_phone), phone_norm = n where id = me;
  return trim(p_phone);
end $$;

-- Only the member a challenge was sent to can accept it
do $$
declare d text;
begin
  d := pg_get_functiondef('public.challenge_preview(text)'::regprocedure);
  d := replace(d, $q$  elsif c.kind = 'person' then
    if private.is_platform_admin()$q$, $q$  elsif c.kind = 'person' and c.target_partner_id is not null and c.target_partner_id <> me then
    why := 'This challenge was sent to another member.';
  elsif c.kind = 'person' then
    if private.is_platform_admin()$q$);
  if position('sent to another member' in d) = 0 then raise exception 'challenge_preview not updated'; end if;
  execute d;
end $$;

create or replace function public.challenge_member_by_phone(p_phone text, p_start date default null, p_end date default null, p_message text default null) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); n text := private.norm_phone(p_phone); hits uuid[]; t uuid; code text; s partners; tp partners;
begin
  if me is null then raise exception 'Please sign in again.'; end if;
  if n is null then raise exception 'Check the phone number. Use the full number with area code.'; end if;
  if (select count(*) from phone_lookups where partner_id = me and at > now() - interval '1 day') >= 20 then
    raise exception 'You''ve looked up 20 phone numbers today. Try again tomorrow, or send the challenge link by text.';
  end if;
  select array_agg(id) into hits from partners where phone_norm = n and id <> me;
  insert into phone_lookups (partner_id, matched) values (me, coalesce(array_length(hits, 1), 0) = 1);
  if coalesce(array_length(hits, 1), 0) = 0 then return json_build_object('found', false); end if;
  if array_length(hits, 1) > 1 then return json_build_object('found', false, 'shared', true); end if;
  t := hits[1];
  if exists (select 1 from challenges where created_by = me and target_partner_id = t and status = 'pending') then
    raise exception 'You already have a challenge waiting for this member.';
  end if;
  code := public.create_challenge('person', p_start, p_end, p_message, null);
  update challenges set target_partner_id = t where invite_code = code;
  select * into s from partners where id = me;
  select * into tp from partners where id = t;
  perform private.queue_email(tp.email, h(s.first_name) || ' challenged you to the Time4God Challenge',
    array['Hi ' || h(tp.first_name) || ',',
          h(s.first_name || ' ' || s.last_name) || ' challenged you to the Time4God Challenge: who will give the most time to God?' ||
            coalesce('<br><br><em>“' || h(nullif(trim(p_message), '')) || '”</em>', ''),
          'Open your Challenges page to accept or decline.'],
    'See the challenge', 'https://time4god.app/challenges.html?c=' || code, null, 'challenge.direct');
  return json_build_object('found', true, 'code', code);
end $$;

-- Challenges sent to me, waiting for my answer
create or replace function public.my_incoming_challenges() returns json
language sql stable security definer set search_path = public, private as $$
  select coalesce(json_agg(json_build_object('code', c.invite_code, 'from', p.first_name || ' ' || p.last_name, 'message', c.message,
      'start_date', c.start_date, 'end_date', c.end_date, 'created_at', c.created_at) order by c.created_at desc), '[]'::json)
  from challenges c join partners p on p.id = c.created_by
  where c.target_partner_id = private.my_partner_id() and c.status = 'pending' $$;

revoke execute on function public.my_phone(), public.set_my_phone(text), public.challenge_member_by_phone(text, date, date, text), public.my_incoming_challenges() from public, anon;
grant execute on function public.my_phone(), public.set_my_phone(text), public.challenge_member_by_phone(text, date, date, text), public.my_incoming_challenges() to authenticated;
