-- 0016: "Give one". Every paid individual purchase includes one guest seat.
--  * The buyer uses it by sending a person-to-person challenge. The person who accepts
--    gets the full study book in the app from the day they accept until the challenge ends.
--  * A guest seat can't send challenges and doesn't come with a guest seat of its own.
--  * An unused guest seat stays with the buyer for as long as the buyer's own year lasts.
--  * Guests can "keep going": their own year at the current individual price minus $5,
--    from the day they accept until 30 days after their challenge ends. That purchase
--    includes a guest seat too.
--  * Sending a person challenge now needs the study book (own seat, book key, church seat,
--    or a leader of a licensed church). Group and church challenges are unchanged.

create table public.guest_passes (
  id uuid primary key default gen_random_uuid(),
  owner_partner_id uuid not null references public.partners(id) on delete cascade,
  payment_id uuid unique references public.payments(id) on delete set null,
  created_at timestamptz not null default now(),
  claimed_by uuid references public.partners(id) on delete set null,
  claimed_at timestamptz,
  challenge_id uuid references public.challenges(id) on delete set null,
  access_until date
);
create index on public.guest_passes (owner_partner_id);
create index on public.guest_passes (claimed_by);
alter table public.guest_passes enable row level security;
-- No policies: reached only through the functions below.
revoke all on public.guest_passes from anon, authenticated;

alter table public.payments add column if not exists discount numeric(10,2) not null default 0;

-- ---------- helpers ----------
create or replace function private.keep_going_discount() returns numeric
language sql immutable as $$ select 5.00::numeric $$;

-- The study book through a purchase, book key, church seat or leader role (not a guest seat)
create or replace function private.paid_access(pid uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select pid is not null and (
    private.has_individual_seat(pid)
    or exists (select 1 from memberships m where m.partner_id = pid and m.status = 'verified'
                 and (private.current_church_license(m.church_id)).status = 'active')
    or exists (select 1 from role_assignments r join partners p on p.auth_user_id = r.user_id
                 where p.id = pid and r.role in ('church_admin', 'table_leader') and r.verified_at is not null and r.revoked_at is null
                   and (private.current_church_license(r.church_id)).status = 'active')) $$;

create or replace function private.guest_until(pid uuid) returns date
language sql stable security definer set search_path = public as $$
  select max(access_until) from guest_passes where claimed_by = pid $$;

-- Unused guest seats a member can give right now (their own year must still be running)
create or replace function private.guest_seats_left(pid uuid) returns int
language sql stable security definer set search_path = public, private as $$
  select case when private.has_individual_seat(pid)
    then (select count(*)::int from guest_passes where owner_partner_id = pid and claimed_by is null) else 0 end $$;

-- The "keep going" price for this member, or null when it doesn't apply
create or replace function private.keep_going_price(pid uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select case when pid is not null and not private.has_individual_seat(pid)
                and private.guest_until(pid) >= current_date - 30
    then greatest((select price from license_plans where kind = 'individual' and active order by sort_order limit 1) - private.keep_going_discount(), 0.50) end $$;

-- ---------- reading access ----------
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

create or replace function public.my_access() returns json
language plpgsql stable security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); m record; seat record; g record; gu date;
begin
  select ms.status, c.name, (private.current_church_license(ms.church_id)).status as lic into m
  from memberships ms join churches c on c.id = ms.church_id where ms.partner_id = pid and ms.status in ('pending', 'verified') limit 1;
  select i.expires_at, i.price into seat from individual_seats i, seasons s
  where s.active and i.partner_id = pid and i.status = 'active' and private.license_covers(i.season_id, i.expires_at, s)
  order by i.expires_at desc nulls last limit 1;
  gu := private.guest_until(pid);
  select (select first_name from partners where id = gp.owner_partner_id) as giver into g
  from guest_passes gp where gp.claimed_by = pid order by gp.access_until desc limit 1;
  return json_build_object('church', m.name, 'church_status', m.status, 'church_license', m.lic,
    'church_covers', m.status = 'verified' and m.lic = 'active',
    'seat', seat.expires_at is not null or seat.price is not null, 'seat_expires', seat.expires_at,
    'guest_until', gu, 'guest_active', coalesce(gu >= current_date, false), 'guest_from', g.giver,
    'keep_going_price', private.keep_going_price(pid),
    'guest_seats_left', private.guest_seats_left(pid),
    'guest_seat_given_to', (select p.first_name from guest_passes gp join partners p on p.id = gp.claimed_by
                            where gp.owner_partner_id = pid order by gp.claimed_at desc limit 1),
    'admin', private.is_platform_admin());
end $$;

-- ---------- what can be bought ----------
create or replace function public.purchase_options(cid uuid default null)
returns json language plpgsql stable security definer set search_path = public, private as $$
declare l church_licenses; ind license_plans; me uuid := private.my_partner_id();
begin
  select * into ind from license_plans where kind = 'individual' and active order by sort_order limit 1;
  if cid is null then
    return json_build_object('individual_price', ind.price, 'has_seat', private.has_individual_seat(me),
      'keep_going_price', private.keep_going_price(me), 'discount', private.keep_going_discount());
  end if;
  if not private.manages_church(cid) then raise exception 'Only the church admin can buy seats for this church.'; end if;
  l := private.current_church_license(cid);
  return json_build_object(
    'current', case when l.id is not null then json_build_object('seats', l.seats, 'price', l.price, 'status', l.status, 'expires_at', l.expires_at,
                     'plan', (select name from license_plans where id = l.plan_id)) end,
    'used', (select count(*) from memberships where church_id = cid and status = 'verified'),
    'plans', (select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'seats', p.seat_limit, 'price', p.price,
                'due', case when l.status = 'active' then case when p.seat_limit > l.seats then greatest(p.price - l.price, 0) end
                            else p.price end) order by p.sort_order), '[]'::json)
              from license_plans p where p.kind = 'church' and p.active));
end $$;

create or replace function public.stripe_prepare(p_user uuid, p_type text, p_church uuid, p_plan uuid)
returns json language plpgsql security definer set search_path = public, private as $$
declare pid uuid; em text; s seasons; p license_plans; l church_licenses; amt numeric; k text; d text; pay uuid; ch churches; boss boolean; disc numeric := 0;
begin
  select id, email into pid, em from partners where auth_user_id = p_user;
  if pid is null then raise exception 'Create your account first.'; end if;
  select * into s from seasons where active limit 1;
  if s.id is null then raise exception 'No season is open yet.'; end if;
  if p_type in ('individual', 'keep_going') then
    select * into p from license_plans where kind = 'individual' and active order by sort_order limit 1;
    if p.id is null then raise exception 'Individual seats are not available right now.'; end if;
    if private.has_individual_seat(pid) then raise exception 'You already have the book in the app.'; end if;
    k := 'individual';
    if p_type = 'keep_going' then
      amt := private.keep_going_price(pid);
      if amt is null then raise exception 'The keep-going price is for guests of a Time4God Challenge.'; end if;
      disc := p.price - amt;
      d := 'Time4God Challenge · keep going, book in the app (1 year)';
    else
      amt := p.price; d := 'Time4God Challenge · book in the app (1 year)';
    end if;
  elsif p_type = 'church' then
    select * into ch from churches where id = p_church;
    if ch.id is null then raise exception 'That church was not found.'; end if;
    boss := exists (select 1 from role_assignments r where r.user_id = p_user and r.revoked_at is null and r.verified_at is not null
                      and (r.role = 'platform_admin' or (r.role = 'church_admin' and r.church_id = p_church)));
    if not boss then raise exception 'Only the church admin can buy seats for this church.'; end if;
    select * into p from license_plans where id = p_plan and kind = 'church' and active;
    if p.id is null then raise exception 'Choose a seat plan.'; end if;
    l := private.current_church_license(p_church);
    if l.id is not null and l.status = 'active' then
      if p.seat_limit <= l.seats then raise exception 'Choose a larger plan to add seats.'; end if;
      k := 'church_upgrade'; amt := p.price - l.price;
      d := ch.name || ' · upgrade to ' || p.name || ' (' || p.seat_limit || ' seats)';
    else
      k := 'church_new'; amt := p.price; l := null;
      d := ch.name || ' · ' || p.name || ' (' || p.seat_limit || ' seats, 1 year)';
    end if;
  else
    raise exception 'Unknown purchase.';
  end if;
  if amt is null or amt < 0.5 then raise exception 'Nothing to pay for that choice.'; end if;
  insert into payments (kind, buyer_partner_id, buyer_email, church_id, plan_id, license_id, description, amount, discount)
  values (k, pid, em, p_church, p.id, l.id, d, amt, disc) returning id into pay;
  return json_build_object('payment_id', pay, 'amount_cents', (amt * 100)::int, 'description', d, 'email', em);
end $$;

create or replace function public.stripe_activate(p_session text, p_intent text, p_amount_cents int)
returns text language plpgsql security definer set search_path = public, private as $$
declare pay payments; s seasons; p license_plans; lid uuid;
begin
  select * into pay from payments where stripe_session_id = p_session for update;
  if pay.id is null then raise exception 'Payment not found.'; end if;
  if pay.status = 'paid' then return 'already'; end if;
  if p_amount_cents <> (pay.amount * 100)::int then raise exception 'Paid amount does not match.'; end if;
  select * into s from seasons where active limit 1;
  select * into p from license_plans where id = pay.plan_id;
  if pay.kind = 'individual' then
    insert into individual_seats (partner_id, season_id, plan_id, price, status, paid_at, expires_at)
    values (pay.buyer_partner_id, s.id, pay.plan_id, pay.amount, 'active', now(), now() + interval '1 year')
    on conflict (partner_id, season_id) do update set status = 'active', plan_id = excluded.plan_id, price = excluded.price, paid_at = now(), expires_at = now() + interval '1 year';
    -- Give one: every paid individual purchase includes one guest seat
    insert into guest_passes (owner_partner_id, payment_id) values (pay.buyer_partner_id, pay.id) on conflict (payment_id) do nothing;
  elsif pay.kind = 'church_new' then
    insert into church_licenses (church_id, season_id, plan_id, seats, price, status, paid_at, expires_at)
    values (pay.church_id, s.id, pay.plan_id, p.seat_limit, pay.amount, 'active', now(), now() + interval '1 year')
    on conflict (church_id, season_id) do update set plan_id = excluded.plan_id, seats = excluded.seats, price = excluded.price,
      status = 'active', paid_at = now(), expires_at = now() + interval '1 year', updated_at = now()
    returning id into lid;
    update payments set license_id = lid where id = pay.id;
  else
    update church_licenses set plan_id = p.id, seats = p.seat_limit, price = price + pay.amount, updated_at = now()
      where id = pay.license_id;
  end if;
  update payments set status = 'paid', paid_at = now(), stripe_payment_intent = p_intent where id = pay.id;
  insert into audit_logs (actor_id, organization_id, action, resource_type, resource_id, metadata)
    values (null, pay.church_id, 'payment.paid', 'payment', pay.id::text, jsonb_build_object('amount', pay.amount, 'kind', pay.kind));
  return 'paid';
end $$;

-- Anyone who already paid for an individual seat gets their guest seat too
insert into guest_passes (owner_partner_id, payment_id)
select buyer_partner_id, id from payments where kind = 'individual' and status = 'paid' and buyer_partner_id is not null
on conflict (payment_id) do nothing;

-- ---------- challenges ----------
create or replace function public.challenge_options()
returns json language plpgsql stable security definer set search_path = public, private as $$
declare s seasons; t uuid := private.my_led_table(); ch uuid := private.my_admin_church(); st date; me uuid := private.my_partner_id();
begin
  select * into s from seasons where active;
  st := greatest(coalesce(s.start_date, current_date), current_date);
  return json_build_object(
    'has_account', me is not null,
    'group_id', t, 'group_name', (select tb.name || ' · ' || c.name from tables tb join churches c on c.id = tb.church_id where tb.id = t),
    'church_id', ch, 'church_name', (select name from churches where id = ch),
    'season_name', s.name, 'default_start', st, 'default_end', st + 84,
    'can_person', private.is_platform_admin() or coalesce(private.paid_access(me), false),
    'guest_seats_left', private.guest_seats_left(me),
    'guest_until', private.guest_until(me),
    'keep_going_price', private.keep_going_price(me),
    'individual_price', (select price from license_plans where kind = 'individual' and active order by sort_order limit 1));
end $$;

create or replace function public.create_challenge(p_kind text, p_start date default null, p_end date default null, p_message text default null, p_title text default null)
returns text language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); s seasons; st date; en date; code text; t uuid; ch uuid;
begin
  if me is null then raise exception 'Create your account first.'; end if;
  if p_kind not in ('person', 'group', 'church', 'church_open') then raise exception 'Choose a kind of challenge.'; end if;
  if p_kind = 'person' and not (private.is_platform_admin() or private.paid_access(me)) then
    if coalesce(private.guest_until(me) >= current_date - 30, false) then
      raise exception 'Your guest seat lets you accept a challenge. To challenge someone yourself, get your own year of the study book.';
    end if;
    raise exception 'Get the study book to challenge someone. Your purchase includes a seat to give the person you challenge.';
  end if;
  if (select count(*) from challenges where created_by = me and status = 'pending') >= 25 then
    raise exception 'You have 25 challenges waiting for an answer. Cancel some before sending more.';
  end if;
  select * into s from seasons where active;
  st := coalesce(p_start, greatest(coalesce(s.start_date, current_date), current_date));
  en := coalesce(p_end, st + 84);
  if st < current_date then raise exception 'The start date can''t be in the past.'; end if;
  if en < st then raise exception 'The end date must be after the start date.'; end if;
  if en - st > 84 then raise exception 'A challenge can last up to 12 weeks.'; end if;
  code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  if p_kind = 'person' then
    insert into challenges (invite_code, kind, title, message, start_date, end_date, created_by, a_partner)
    values (code, 'person', nullif(trim(p_title), ''), nullif(trim(p_message), ''), st, en, me, me);
  elsif p_kind = 'group' then
    t := private.my_led_table();
    if t is null then raise exception 'Only a group leader who belongs to a group can send a group challenge.'; end if;
    insert into challenges (invite_code, kind, title, message, start_date, end_date, created_by, a_table)
    values (code, 'group', nullif(trim(p_title), ''), nullif(trim(p_message), ''), st, en, me, t);
  else
    ch := private.my_admin_church();
    if ch is null then raise exception 'Only a church admin can send a church challenge.'; end if;
    insert into challenges (invite_code, kind, status, title, message, start_date, end_date, created_by, a_church)
    values (code, p_kind, case when p_kind = 'church_open' then 'active' else 'pending' end,
            coalesce(nullif(trim(p_title), ''), case when p_kind = 'church_open' then 'Time4God Challenge' end),
            nullif(trim(p_message), ''), st, en, me, ch);
  end if;
  return code;
end $$;

-- What an invitation link shows. For person challenges it also says whether the sender's
-- guest seat comes with it, and whether the person accepting needs the study book first.
create or replace function public.challenge_preview(p_code text)
returns json language plpgsql stable security definer set search_path = public, private as $$
declare c challenges; me uuid := private.my_partner_id(); can boolean := false; why text; t uuid; ch uuid;
        gift boolean := false; uses boolean := false; needs boolean := false;
begin
  select * into c from challenges where invite_code = upper(trim(p_code));
  if c.id is null then return null; end if;
  if c.kind = 'person' and c.status = 'pending' then gift := private.guest_seats_left(c.created_by) > 0; end if;
  if c.kind = 'church_open' then
    can := false; why := 'This challenge is for members of ' || private.challenge_side_name(c, 1) || '. Members join it in the app.';
  elsif c.status <> 'pending' then
    why := case c.status when 'active' then 'This challenge has already been accepted.' when 'declined' then 'This challenge was declined.' else 'This challenge was canceled.' end;
  elsif auth.uid() is null then
    why := 'Sign in to accept.';
  elsif me is null then
    why := 'Create your account first.';
  elsif c.created_by = me then
    why := 'You sent this challenge. Share the link with the person you want to challenge.';
  elsif c.kind = 'person' then
    if private.is_platform_admin() or private.paid_access(me) or coalesce(private.guest_until(me) >= c.end_date, false) then
      can := true;
    elsif gift then
      can := true; uses := true;
    else
      needs := true;
      why := 'To accept, get the study book in the app. ' || coalesce((select first_name from partners where id = c.created_by), 'The sender') || '’s guest seat has already been given.';
    end if;
  elsif c.kind = 'group' then
    t := private.my_led_table();
    if t is null then why := 'Only a group leader can accept a group challenge for their group.';
    elsif t = c.a_table then why := 'Your group sent this challenge.';
    else can := true; end if;
  elsif c.kind = 'church' then
    ch := private.my_admin_church();
    if ch is null then why := 'Only your church admin can accept a church challenge. Forward this link to them.';
    elsif ch = c.a_church then why := 'Your church sent this challenge.';
    else can := true; end if;
  end if;
  return json_build_object('kind', c.kind, 'status', c.status, 'title', c.title, 'message', c.message,
    'start_date', c.start_date, 'end_date', c.end_date, 'from_name', private.challenge_side_name(c, 1),
    'sender', (select first_name from partners where id = c.created_by),
    'gift', gift, 'uses_guest_seat', uses, 'needs_book', needs,
    'can_accept', can, 'reason', why, 'id', case when can or c.created_by = me then c.id end);
end $$;

create or replace function public.respond_to_challenge(p_code text, p_accept boolean)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare c challenges; p json; me uuid := private.my_partner_id(); gp uuid;
begin
  select * into c from challenges where invite_code = upper(trim(p_code)) for update;
  if c.id is null then raise exception 'That challenge was not found.'; end if;
  p := public.challenge_preview(p_code);
  if p_accept and not (p->>'can_accept')::boolean then raise exception '%', coalesce(p->>'reason', 'You can''t answer this challenge.'); end if;
  if not p_accept and not ((p->>'can_accept')::boolean or (p->>'needs_book')::boolean) then raise exception '%', coalesce(p->>'reason', 'You can''t answer this challenge.'); end if;
  if p_accept then
    if (p->>'uses_guest_seat')::boolean then
      select id into gp from guest_passes where owner_partner_id = c.created_by and claimed_by is null
        order by created_at limit 1 for update skip locked;
      if gp is null then raise exception 'The guest seat for this challenge was just used. Get the study book to accept.'; end if;
      update guest_passes set claimed_by = me, claimed_at = now(), challenge_id = c.id, access_until = c.end_date where id = gp;
    end if;
    update challenges set status = 'active', responded_by = me, responded_at = now(),
      b_partner = case when kind = 'person' then me end,
      b_table = case when kind = 'group' then private.my_led_table() end,
      b_church = case when kind = 'church' then private.my_admin_church() end
    where id = c.id;
  else
    update challenges set status = 'declined', responded_by = me, responded_at = now() where id = c.id;
  end if;
  return c.id;
end $$;

-- ---------- Admin Panel dashboard: add guest seats ----------
alter function public.admin_dashboard() set schema private;
alter function private.admin_dashboard() rename to admin_dashboard_base;
create function public.admin_dashboard() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  return (private.admin_dashboard_base()::jsonb || jsonb_build_object('guests', jsonb_build_object(
    'given', (select count(*) from guest_passes),
    'used', (select count(*) from guest_passes where claimed_by is not null),
    'active', (select count(*) from guest_passes where access_until >= current_date),
    'kept_going', (select count(*) from guest_passes gp where gp.claimed_by is not null
                     and exists (select 1 from payments p where p.buyer_partner_id = gp.claimed_by and p.status = 'paid' and p.kind = 'individual'))
  )))::json;
end $$;

-- ---------- grants ----------
revoke execute on function private.admin_dashboard_base() from public, anon;
grant execute on function private.admin_dashboard_base() to authenticated;
revoke execute on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;
revoke execute on function private.keep_going_discount(), private.paid_access(uuid), private.guest_until(uuid), private.guest_seats_left(uuid), private.keep_going_price(uuid) from public, anon;
grant execute on function private.keep_going_discount(), private.paid_access(uuid), private.guest_until(uuid), private.guest_seats_left(uuid), private.keep_going_price(uuid) to authenticated;
revoke execute on function public.stripe_prepare(uuid, text, uuid, uuid), public.stripe_activate(text, text, int) from public, anon, authenticated;
grant execute on function public.stripe_prepare(uuid, text, uuid, uuid), public.stripe_activate(text, text, int) to service_role;
revoke execute on function public.my_access(), public.purchase_options(uuid), public.challenge_options(), public.create_challenge(text, date, date, text, text), public.respond_to_challenge(text, boolean) from public, anon;
grant execute on function public.my_access(), public.purchase_options(uuid), public.challenge_options(), public.create_challenge(text, date, date, text, text), public.respond_to_challenge(text, boolean) to authenticated;
revoke execute on function public.challenge_preview(text) from public;
grant execute on function public.challenge_preview(text) to anon, authenticated;
