-- 144(P) Plan — initial schema with row-level security
-- Partners own their spiritual records. Church admins get aggregates only. Platform admins get business data only.

create extension if not exists pgcrypto;

-- ---------- roles ----------
create type app_role as enum ('platform_admin', 'church_admin', 'table_leader', 'partner');
create type sub_status as enum ('pilot', 'active', 'past_due', 'canceled', 'suspended');
create type deposit_category as enum ('praying', 'reading', 'listening', 'present');

-- ---------- tenants ----------
create table churches (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  slug text unique not null,
  name text not null, address text, city text, state text, postal_code text,
  website text, phone text, contact_email text,
  enrollment_policy text not null default 'approval' check (enrollment_policy in ('open','approval')),
  features jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table tables (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references churches(id) on delete cascade,
  name text not null, leader_partner_id uuid, status text not null default 'active',
  created_at timestamptz not null default now()
);

-- ---------- people ----------
create table partners (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique not null references auth.users(id) on delete cascade,
  first_name text not null, last_name text not null, email text not null,
  account_start_date date not null default current_date,
  timezone text not null default 'America/New_York',
  giving_plan text,
  created_at timestamptz not null default now()
);
create table role_assignments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  church_id uuid references churches(id) on delete cascade,
  role app_role not null,
  verified_at timestamptz, revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create table memberships (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references partners(id) on delete cascade,
  church_id uuid not null references churches(id) on delete cascade,
  table_id uuid references tables(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','verified','removed')),
  joined_at date not null default current_date,
  last_active_at date
);
create unique index memberships_one_active on memberships(partner_id) where status <> 'removed';

-- ---------- private spiritual records (partner-only) ----------
create table time_deposits (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references partners(id) on delete cascade,
  category deposit_category not null,
  minutes int not null check (minutes between 1 and 1440),
  activity_date date not null, activity_time time,
  entry_method text not null check (entry_method in ('manual','timer')),
  client_key text, -- idempotency for double taps
  created_at timestamptz not null default now(), updated_at timestamptz, voided_at timestamptz,
  unique (partner_id, client_key)
);
create table deposit_notes (  -- separated so notes can never ride along with deposit queries
  deposit_id uuid primary key references time_deposits(id) on delete cascade,
  partner_id uuid not null references partners(id) on delete cascade,
  note text check (char_length(note) <= 300)
);
create table weekly_reflections (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references partners(id) on delete cascade,
  week_start_date date not null,
  meaningful_time text check (char_length(meaningful_time) <= 300),
  next_week_plan text check (char_length(next_week_plan) <= 300),
  updated_at timestamptz not null default now(),
  unique (partner_id, week_start_date)
);
create table active_timers (
  partner_id uuid primary key references partners(id) on delete cascade,
  category deposit_category not null, started_at timestamptz, accumulated_ms bigint not null default 0, running boolean not null default true
);
create table sharing_permissions (
  id uuid primary key default gen_random_uuid(),
  owner_partner_id uuid not null references partners(id) on delete cascade,
  recipient_partner_id uuid references partners(id) on delete cascade,
  recipient_label text, permission_type text not null default 'weekly_balance',
  enabled boolean not null default true, created_at timestamptz not null default now(), revoked_at timestamptz
);
create table notification_preferences (
  partner_id uuid primary key references partners(id) on delete cascade,
  reminder_enabled boolean not null default false, reminder_time time default '07:00',
  email_reminder boolean not null default false, timezone text
);

-- ---------- program config ----------
create table program_weeks (week_number int primary key check (week_number between 1 and 12), chapter_title text, chapter_reference text, description text);
create table milestone_definitions (id uuid primary key default gen_random_uuid(), code text unique not null, title text not null, rules_configuration jsonb, active boolean not null default false);
create table redemption_catalog (
  id uuid primary key default gen_random_uuid(), church_id uuid references churches(id) on delete cascade,
  code text not null, title text not null, description text, minute_cost int not null check (minute_cost > 0),
  enabled boolean not null default false, created_at timestamptz not null default now()
);
create table time_redemptions (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references partners(id) on delete cascade,
  catalog_id uuid references redemption_catalog(id), title text not null, detail text,
  minute_cost int not null check (minute_cost > 0), status text not null default 'confirmed',
  client_key text, created_at timestamptz not null default now(), completed_at timestamptz,
  unique (partner_id, client_key)
);

-- ---------- billing ----------
create table subscription_plans (
  id text primary key, name text not null, monthly_price numeric(10,2), annual_price numeric(10,2),
  active_partner_limit int, enabled_features text[] not null default '{}', status text not null default 'published'
);
insert into subscription_plans values
  ('small','Small Church',29,290,25,'{statements,enrollment}','published'),
  ('growing','Growing Church',59,590,100,'{statements,enrollment,tables}','published'),
  ('large','Large Church',119,1190,500,'{statements,enrollment,tables,reports}','published'),
  ('enterprise','Enterprise',null,null,null,'{all}','published');
create table church_subscriptions (
  id uuid primary key default gen_random_uuid(),
  church_id uuid unique not null references churches(id) on delete cascade,
  plan_id text not null references subscription_plans(id),
  provider_customer_id text, provider_subscription_id text unique,
  billing_frequency text not null check (billing_frequency in ('monthly','annual')),
  contract_price numeric(10,2) not null, discount_pct numeric(5,2) not null default 0,
  included_partners int, status sub_status not null,
  period_start date, period_end date, pilot_end date, cancel_at_period_end boolean not null default false
);
create table invoices (
  id uuid primary key default gen_random_uuid(), church_id uuid not null references churches(id),
  provider_invoice_id text unique, number text, amount numeric(10,2) not null,
  status text not null check (status in ('open','paid','failed','void')), issued_at date, paid_at date
);
create table subscription_events (
  id uuid primary key default gen_random_uuid(), church_id uuid references churches(id),
  subscription_id uuid references church_subscriptions(id), event_type text not null,
  provider_event_id text unique not null, -- webhook idempotency
  payload jsonb, occurred_at timestamptz not null default now()
);
create table church_invitations (
  id uuid primary key default gen_random_uuid(), church_id uuid not null references churches(id) on delete cascade,
  invited_email text not null, invited_name text, invited_title text,
  invitation_token_hash text unique not null, expires_at timestamptz not null, accepted_at timestamptz,
  created_at timestamptz not null default now()
);
create table participation_weekly (  -- aggregate only; written by a server job
  church_id uuid not null references churches(id) on delete cascade, week_start date not null,
  participants int not null, minutes int not null, primary key (church_id, week_start)
);
create table platform_settings (id int primary key default 1 check (id = 1), settings jsonb not null default '{}'::jsonb);
insert into platform_settings (settings) values ('{"privacyThreshold":5,"graceDays":14,"pilotDays":90}');
create table audit_logs (
  id uuid primary key default gen_random_uuid(), actor_id uuid, organization_id uuid,
  action text not null, resource_type text, resource_id text, metadata jsonb, created_at timestamptz not null default now()
);

create index on time_deposits(partner_id, activity_date) where voided_at is null;
create index on memberships(church_id, status);
create index on invoices(church_id, issued_at desc);

-- ---------- helper functions (security definer, fixed search_path) ----------
create or replace function my_partner_id() returns uuid language sql stable security definer set search_path = public as
$$ select id from partners where auth_user_id = auth.uid() $$;
create or replace function is_platform_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from role_assignments where user_id = auth.uid() and role = 'platform_admin' and verified_at is not null and revoked_at is null) $$;
create or replace function is_church_admin(cid uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from role_assignments where user_id = auth.uid() and church_id = cid and role = 'church_admin' and verified_at is not null and revoked_at is null) $$;

-- Balances derived from records (never a mutable total)
create or replace view my_balances with (security_invoker = true) as
select p.id as partner_id,
  coalesce((select sum(minutes) from time_deposits d where d.partner_id = p.id and d.voided_at is null),0) as lifetime_minutes,
  coalesce((select sum(minutes) from time_deposits d where d.partner_id = p.id and d.voided_at is null),0)
  - coalesce((select sum(minute_cost) from time_redemptions r where r.partner_id = p.id and r.status <> 'canceled'),0) as available_minutes
from partners p where p.id = my_partner_id();

-- Transaction-safe redemption: commissioning, balance and idempotency checked server-side
create or replace function redeem_time(p_title text, p_detail text, p_cost int, p_client_key text, p_catalog uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare pid uuid := my_partner_id(); avail int; start date; rid uuid;
begin
  if pid is null then raise exception 'not a partner'; end if;
  perform pg_advisory_xact_lock(hashtext(pid::text));
  select id into rid from time_redemptions where partner_id = pid and client_key = p_client_key;
  if rid is not null then return rid; end if;
  select account_start_date into start from partners where id = pid;
  if current_date < start + 84 then raise exception 'redemption opens at commissioning'; end if;
  select available_minutes into avail from my_balances;
  if avail < p_cost then raise exception 'insufficient available minutes'; end if;
  insert into time_redemptions(partner_id, catalog_id, title, detail, minute_cost, client_key) values (pid, p_catalog, p_title, p_detail, p_cost, p_client_key) returning id into rid;
  insert into audit_logs(actor_id, action, resource_type, resource_id) values (auth.uid(), 'redemption.created', 'time_redemption', rid::text);
  return rid;
end $$;

-- Church aggregate report with privacy suppression
create or replace function church_participation(cid uuid)
returns table(week_start date, participants int, hours numeric) language sql stable security definer set search_path = public as $$
  select w.week_start,
    case when w.participants >= (select (settings->>'privacyThreshold')::int from platform_settings) then w.participants end,
    case when w.participants >= (select (settings->>'privacyThreshold')::int from platform_settings) then round(w.minutes/60.0,1) end
  from participation_weekly w where w.church_id = cid and (is_church_admin(cid) or is_platform_admin()) order by 1
$$;

-- ---------- row-level security ----------
do $$ declare t text; begin
  foreach t in array array['churches','tables','partners','role_assignments','memberships','time_deposits','deposit_notes','weekly_reflections','active_timers','sharing_permissions','notification_preferences','program_weeks','milestone_definitions','redemption_catalog','time_redemptions','subscription_plans','church_subscriptions','invoices','subscription_events','church_invitations','participation_weekly','platform_settings','audit_logs']
  loop execute format('alter table %I enable row level security', t); end loop;
end $$;

-- Partner-owned records: owner only. No admin policy exists, so no admin can read them.
create policy own_partner on partners for all using (auth_user_id = auth.uid()) with check (auth_user_id = auth.uid());
create policy own_deposits on time_deposits for all using (partner_id = my_partner_id()) with check (partner_id = my_partner_id());
create policy own_notes on deposit_notes for all using (partner_id = my_partner_id()) with check (partner_id = my_partner_id());
create policy own_reflections on weekly_reflections for all using (partner_id = my_partner_id()) with check (partner_id = my_partner_id());
create policy own_timer on active_timers for all using (partner_id = my_partner_id()) with check (partner_id = my_partner_id());
create policy own_prefs on notification_preferences for all using (partner_id = my_partner_id()) with check (partner_id = my_partner_id());
create policy own_redemptions_read on time_redemptions for select using (partner_id = my_partner_id()); -- writes only via redeem_time()
create policy own_sharing on sharing_permissions for all using (owner_partner_id = my_partner_id()) with check (owner_partner_id = my_partner_id());
create policy shared_with_me on sharing_permissions for select using (recipient_partner_id = my_partner_id() and enabled and revoked_at is null);

-- Memberships: partner sees own; church admin manages associations for their church (no spiritual data lives here)
create policy own_membership on memberships for select using (partner_id = my_partner_id());
create policy request_membership on memberships for insert with check (partner_id = my_partner_id() and status = 'pending');
create policy church_admin_memberships on memberships for all using (is_church_admin(church_id)) with check (is_church_admin(church_id));

-- Churches & tables: members read their church; admins manage their own; platform reads all
create policy church_read on churches for select using (is_platform_admin() or is_church_admin(id) or exists(select 1 from memberships m where m.church_id = churches.id and m.partner_id = my_partner_id() and m.status <> 'removed'));
create policy church_admin_update on churches for update using (is_church_admin(id)) with check (is_church_admin(id));
create policy platform_church_all on churches for all using (is_platform_admin()) with check (is_platform_admin());
create policy tables_read on tables for select using (is_platform_admin() or is_church_admin(church_id) or exists(select 1 from memberships m where m.church_id = tables.church_id and m.partner_id = my_partner_id()));
create policy tables_admin on tables for all using (is_church_admin(church_id)) with check (is_church_admin(church_id));

-- Billing: church admin reads own church; platform reads all; writes only by service role (webhooks)
create policy plans_read on subscription_plans for select using (true);
create policy plans_admin on subscription_plans for all using (is_platform_admin()) with check (is_platform_admin());
create policy subs_read on church_subscriptions for select using (is_platform_admin() or is_church_admin(church_id));
create policy invoices_read on invoices for select using (is_platform_admin() or is_church_admin(church_id));
create policy events_read on subscription_events for select using (is_platform_admin());
create policy invites_platform on church_invitations for all using (is_platform_admin()) with check (is_platform_admin());
create policy participation_platform on participation_weekly for select using (is_platform_admin()); -- church admins use church_participation()
create policy roles_read_own on role_assignments for select using (user_id = auth.uid() or is_platform_admin());
create policy settings_read on platform_settings for select using (is_platform_admin());
create policy settings_write on platform_settings for update using (is_platform_admin());
create policy program_read on program_weeks for select using (true);
create policy milestones_read on milestone_definitions for select using (true);
create policy catalog_read on redemption_catalog for select using (enabled or is_platform_admin() or is_church_admin(church_id));
create policy audit_platform on audit_logs for select using (is_platform_admin());
-- Note: role_assignments inserts happen only via service role (invitation acceptance edge function). No one can self-assign platform_admin.
