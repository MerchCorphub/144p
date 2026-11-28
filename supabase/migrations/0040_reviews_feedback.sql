-- 0040 Ratings, reviews and feedback
-- Week 6 private check-in, after-week-12 public review (approved by the admin), helpful votes,
-- private "Tell us how to improve" notes, and the admin Reviews screen.

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id) on delete cascade,
  kind text not null check (kind in ('checkin', 'review')),
  stars int not null check (stars between 1 and 5),
  comment text,                 -- check-in one-liner
  discovery text,               -- "What did God show you?"
  changed text,                 -- "What changed in your life or your walk with God?"
  recommend text,               -- "Who would you recommend this to?"
  name_choice text not null default 'initial' check (name_choice in ('initial', 'anonymous')),
  marketing_ok boolean not null default false,
  status text not null check (status in ('private', 'pending', 'approved', 'hidden')),
  helpful_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  reviewed_at timestamptz,
  unique (partner_id, kind)
);
alter table public.reviews enable row level security;
create index if not exists reviews_public_idx on public.reviews (kind, status, helpful_count desc, created_at desc);

create table if not exists public.review_votes (
  review_id uuid not null references public.reviews(id) on delete cascade,
  partner_id uuid not null references public.partners(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (review_id, partner_id)
);
alter table public.review_votes enable row level security;

create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid references public.partners(id) on delete cascade,
  email text,
  name text,
  note text not null,
  screen text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;
-- No policies: members never read these tables directly. Everything goes through the functions below.

create or replace function private.review_name(p_partner uuid, p_choice text) returns text
language sql stable security definer set search_path = public, private as $$
  select case when p_choice = 'anonymous' or private.family_access(p_partner) or coalesce(trim(p.first_name), '') = ''
              then 'time4god member'
              else initcap(trim(p.first_name)) || coalesce(' ' || upper(left(nullif(trim(p.last_name), ''), 1)) || '.', '') end
  from partners p where p.id = p_partner $$;

create or replace function private.plan_week(p_partner uuid) returns int
language sql stable security definer set search_path = public, private as $$
  select ((now() at time zone coalesce(nullif(p.timezone, ''), 'America/New_York'))::date - p.account_start_date) / 7 + 1
  from partners p where p.id = p_partner $$;

-- What the member's app needs: is a check-in or review due, and what they already sent.
create or replace function public.my_review_state() returns json
language plpgsql stable security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); w int; adm boolean := private.is_platform_admin(); c reviews; r reviews; teen boolean;
begin
  if me is null then return null; end if;
  w := private.plan_week(me); teen := private.family_access(me);
  select * into c from reviews where partner_id = me and kind = 'checkin';
  select * into r from reviews where partner_id = me and kind = 'review';
  return json_build_object(
    'week', w, 'teen', teen,
    'checkin_open', w >= 7 or adm, 'review_open', w >= 13 or adm,
    'checkin', case when c.id is null then null else json_build_object('stars', c.stars, 'comment', c.comment, 'at', c.created_at) end,
    'review', case when r.id is null then null else json_build_object('stars', r.stars, 'discovery', r.discovery, 'changed', r.changed,
      'recommend', r.recommend, 'name_choice', r.name_choice, 'marketing_ok', r.marketing_ok, 'status', r.status, 'updated_at', r.updated_at) end,
    'show_as', private.review_name(me, coalesce(r.name_choice, 'initial')),
    'show_as_initial', private.review_name(me, 'initial'));
end $$;

create or replace function public.submit_checkin(p_stars int, p_comment text default null) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id();
begin
  if me is null then raise exception 'Please sign in again.'; end if;
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'Pick 1 to 5 stars.'; end if;
  if private.plan_week(me) < 7 and not private.is_platform_admin() then raise exception 'The check-in opens after Week 6.'; end if;
  insert into reviews (partner_id, kind, stars, comment, status)
  values (me, 'checkin', p_stars, nullif(left(trim(coalesce(p_comment, '')), 200), ''), 'private')
  on conflict (partner_id, kind) do update set stars = excluded.stars,
    comment = coalesce(excluded.comment, reviews.comment), updated_at = now();
  return public.my_review_state();
end $$;

create or replace function public.submit_review(p_stars int, p_discovery text, p_changed text, p_recommend text,
  p_name_choice text default 'initial', p_marketing boolean default false) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); teen boolean;
begin
  if me is null then raise exception 'Please sign in again.'; end if;
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'Pick 1 to 5 stars.'; end if;
  if private.plan_week(me) < 13 and not private.is_platform_admin() then raise exception 'Reviews open after you finish Week 12.'; end if;
  teen := private.family_access(me);
  insert into reviews (partner_id, kind, stars, discovery, changed, recommend, name_choice, marketing_ok, status)
  values (me, 'review', p_stars, nullif(left(trim(coalesce(p_discovery, '')), 80), ''),
    nullif(left(trim(coalesce(p_changed, '')), 1000), ''), nullif(left(trim(coalesce(p_recommend, '')), 300), ''),
    case when teen or p_name_choice = 'anonymous' then 'anonymous' else 'initial' end,
    coalesce(p_marketing, false) and not teen, 'pending')
  on conflict (partner_id, kind) do update set stars = excluded.stars, discovery = excluded.discovery,
    changed = excluded.changed, recommend = excluded.recommend, name_choice = excluded.name_choice,
    marketing_ok = excluded.marketing_ok, status = 'pending', reviewed_at = null, updated_at = now();
  return public.my_review_state();
end $$;

-- Public: approved reviews only. Safe to call signed out.
create or replace function public.public_reviews(p_filter text default null, p_offset int default 0, p_limit int default 10) returns json
language plpgsql stable security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); out json;
begin
  select json_build_object(
    'average', (select round(avg(stars)::numeric, 1) from reviews where kind = 'review' and status = 'approved'),
    'count', (select count(*) from reviews where kind = 'review' and status = 'approved'),
    'breakdown', (select json_build_object('5', count(*) filter (where stars = 5), '4', count(*) filter (where stars = 4),
        '3', count(*) filter (where stars = 3), '2', count(*) filter (where stars = 2), '1', count(*) filter (where stars = 1))
      from reviews where kind = 'review' and status = 'approved'),
    'filters', (select coalesce(json_agg(json_build_object('label', discovery, 'n', n) order by n desc, discovery), '[]'::json)
      from (select discovery, count(*) n from reviews where kind = 'review' and status = 'approved' and discovery is not null group by discovery) f),
    'matching', (select count(*) from reviews where kind = 'review' and status = 'approved' and (p_filter is null or discovery = p_filter)),
    'items', (select coalesce(json_agg(x), '[]'::json) from (
      select r.id, r.stars, r.discovery, r.changed, r.recommend, r.helpful_count as helpful,
        private.review_name(r.partner_id, r.name_choice) as name, to_char(coalesce(r.reviewed_at, r.created_at), 'Mon YYYY') as month,
        (me is not null and exists (select 1 from review_votes v where v.review_id = r.id and v.partner_id = me)) as voted,
        (me is not null and r.partner_id = me) as mine
      from reviews r where r.kind = 'review' and r.status = 'approved' and (p_filter is null or r.discovery = p_filter)
      order by r.helpful_count desc, coalesce(r.reviewed_at, r.created_at) desc
      offset greatest(coalesce(p_offset, 0), 0) limit least(greatest(coalesce(p_limit, 10), 1), 50)) x)) into out;
  return out;
end $$;

create or replace function public.review_vote(p_review uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); owner uuid; on_now boolean; n int;
begin
  if me is null then raise exception 'Sign in to mark reviews helpful.'; end if;
  select partner_id into owner from reviews where id = p_review and kind = 'review' and status = 'approved';
  if owner is null then raise exception 'That review is no longer available.'; end if;
  if owner = me then raise exception 'You can’t vote on your own review.'; end if;
  delete from review_votes where review_id = p_review and partner_id = me;
  if found then on_now := false; else insert into review_votes (review_id, partner_id) values (p_review, me); on_now := true; end if;
  update reviews set helpful_count = (select count(*) from review_votes where review_id = p_review) where id = p_review returning helpful_count into n;
  return json_build_object('voted', on_now, 'helpful', n);
end $$;

create or replace function public.send_feedback(p_note text, p_screen text default null) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); p partners;
begin
  if me is null then raise exception 'Please sign in again.'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Write a short note first.'; end if;
  if (select count(*) from feedback where partner_id = me and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Thanks for all your notes! Please try again in an hour.'; end if;
  select * into p from partners where id = me;
  insert into feedback (partner_id, email, name, note, screen)
  values (me, p.email, trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')), left(trim(p_note), 2000), left(p_screen, 40));
  return true;
end $$;

-- ---------- Admin ----------
create or replace function public.admin_reviews(p_view text default 'pending') returns json
language plpgsql stable security definer set search_path = public, private as $$
declare out json;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see reviews.'; end if;
  select json_build_object(
    'counts', json_build_object(
      'pending', (select count(*) from reviews where kind = 'review' and status = 'pending'),
      'live', (select count(*) from reviews where kind = 'review' and status = 'approved'),
      'hidden', (select count(*) from reviews where kind = 'review' and status = 'hidden'),
      'checkins', (select count(*) from reviews where kind = 'checkin'),
      'feedback_new', (select count(*) from feedback where not is_read),
      'feedback', (select count(*) from feedback)),
    'checkin_avg', (select round(avg(stars)::numeric, 1) from reviews where kind = 'checkin'),
    'review_avg', (select round(avg(stars)::numeric, 1) from reviews where kind = 'review' and status = 'approved'),
    'items', case
      when p_view = 'feedback' then (select coalesce(json_agg(x order by x.is_read, x.created_at desc), '[]'::json) from (
        select f.id, f.name, f.email, f.note, f.screen, f.is_read, f.created_at from feedback f order by f.created_at desc limit 200) x)
      when p_view = 'checkins' then (select coalesce(json_agg(x order by x.updated_at desc), '[]'::json) from (
        select r.id, r.stars, r.comment, r.updated_at, trim(p.first_name || ' ' || coalesce(p.last_name, '')) as member, p.email
        from reviews r join partners p on p.id = r.partner_id where r.kind = 'checkin' order by r.updated_at desc limit 200) x)
      else (select coalesce(json_agg(x order by x.updated_at desc), '[]'::json) from (
        select r.id, r.stars, r.discovery, r.changed, r.recommend, r.marketing_ok, r.helpful_count, r.status, r.updated_at,
          r.created_at <> r.updated_at as edited,
          trim(p.first_name || ' ' || coalesce(p.last_name, '')) as member, p.email,
          private.review_name(r.partner_id, r.name_choice) as shows_as, private.family_access(r.partner_id) as teen
        from reviews r join partners p on p.id = r.partner_id
        where r.kind = 'review' and r.status = case p_view when 'live' then 'approved' when 'hidden' then 'hidden' else 'pending' end
        order by r.updated_at desc limit 200) x) end) into out;
  return out;
end $$;

create or replace function public.admin_set_review(p_review uuid, p_status text) returns boolean
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can approve reviews.'; end if;
  if p_status not in ('approved', 'hidden') then raise exception 'Choose Approve or Hide.'; end if;
  update reviews set status = p_status, reviewed_at = now() where id = p_review and kind = 'review';
  if not found then raise exception 'Review not found.'; end if;
  insert into audit_logs(action, resource_type) values ('review.' || p_status, 'review');
  return true;
end $$;

create or replace function public.admin_feedback_read(p_id uuid, p_read boolean default true) returns boolean
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can read feedback.'; end if;
  update feedback set is_read = coalesce(p_read, true) where id = p_id;
  return true;
end $$;

revoke all on function public.my_review_state(), public.submit_checkin(int, text),
  public.submit_review(int, text, text, text, text, boolean), public.review_vote(uuid), public.send_feedback(text, text),
  public.admin_reviews(text), public.admin_set_review(uuid, text), public.admin_feedback_read(uuid, boolean) from public, anon;
grant execute on function public.my_review_state(), public.submit_checkin(int, text),
  public.submit_review(int, text, text, text, text, boolean), public.review_vote(uuid), public.send_feedback(text, text),
  public.admin_reviews(text), public.admin_set_review(uuid, text), public.admin_feedback_read(uuid, boolean) to authenticated;
grant execute on function public.public_reviews(text, int, int) to anon, authenticated;
revoke all on function private.review_name(uuid, text), private.plan_week(uuid) from public, anon, authenticated;
