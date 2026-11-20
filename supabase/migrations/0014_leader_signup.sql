-- 0014: leaders sign up on their own.
--   Church leader: requests a church; it stays "pending" until the platform admin approves,
--     then the requester becomes its church admin and an approved member.
--   Group leader, two ways:
--     a) inside a church already in the app: asks to lead a group; the church admin approves
--        (creates the group or picks an existing one) and the requester becomes its leader;
--     b) independent group (home Bible study, workplace, family): requested like a church
--        (kind = 'group') and approved by the platform admin.
-- Pending or declined churches can't be joined.

alter table public.churches add column if not exists kind text not null default 'church' check (kind in ('church', 'group'));
alter table public.churches add column if not exists status text not null default 'active' check (status in ('pending', 'active', 'declined'));
alter table public.churches add column if not exists requested_by uuid references public.partners(id) on delete set null;
alter table public.churches add column if not exists request_note text;
alter table public.churches add column if not exists decided_at timestamptz;

create table public.group_lead_requests (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references public.churches(id) on delete cascade,
  partner_id uuid not null references public.partners(id) on delete cascade,
  group_name text not null check (char_length(group_name) between 2 and 60),
  note text check (char_length(note) <= 300),
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  table_id uuid references public.tables(id) on delete set null
);
create unique index group_lead_one_pending on public.group_lead_requests (church_id, partner_id) where status = 'pending';
alter table public.group_lead_requests enable row level security;

-- ---------- joining only works for approved churches ----------
create or replace function public.church_by_slug(p_slug text)
returns table (id uuid, name text, enrollment_policy text)
language sql stable security definer set search_path = public as $$
  select id, name, enrollment_policy from churches where slug = p_slug and status = 'active' $$;

create or replace function public.join_church(p_slug text) returns text
language plpgsql security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); ch churches; st text;
begin
  if pid is null then raise exception 'not a partner'; end if;
  select * into ch from churches where slug = p_slug and status = 'active'; if ch.id is null then raise exception 'church not found'; end if;
  select status into st from memberships where partner_id = pid and church_id = ch.id and status <> 'removed';
  if st is not null then return st; end if;
  update memberships set status = 'removed', table_id = null where partner_id = pid and status <> 'removed';
  st := case when ch.enrollment_policy = 'open' then 'verified' else 'pending' end;
  insert into memberships(partner_id, church_id, status, last_active_at) values (pid, ch.id, st, current_date);
  insert into audit_logs(actor_id, organization_id, action, resource_type) values (auth.uid(), ch.id, 'membership.requested', 'membership');
  return st;
end $$;

create or replace function public.join_church_by_code(p_code text) returns text
language plpgsql security definer set search_path = public, private as $$
declare pid uuid := private.my_partner_id(); ch churches; st text;
begin
  if pid is null then raise exception 'Create your account first.'; end if;
  select * into ch from churches where upper(code) = upper(trim(p_code));
  if ch.id is null or ch.status = 'declined' then raise exception 'That church code was not found. Check it with your group leader.'; end if;
  if ch.status = 'pending' then raise exception 'That church is still being set up. Please try again after it''s approved.'; end if;
  select status into st from memberships where partner_id = pid and church_id = ch.id and status <> 'removed';
  if st is not null then return st; end if;
  update memberships set status = 'removed', table_id = null where partner_id = pid and status <> 'removed';
  st := case when ch.enrollment_policy = 'open' then 'verified' else 'pending' end;
  insert into memberships (partner_id, church_id, status, last_active_at) values (pid, ch.id, st, current_date);
  insert into audit_logs (actor_id, organization_id, action, resource_type) values (auth.uid(), ch.id, 'membership.requested', 'membership');
  return st;
end $$;

-- ---------- church / independent group requests ----------
create or replace function public.request_organization(p_kind text, p_name text, p_city text, p_state text, p_phone text, p_website text, p_role text, p_note text)
returns json language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); nm text := nullif(trim(p_name), ''); v_code text; sl text; cid uuid;
  A text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  if me is null then raise exception 'Create your free account first.'; end if;
  if p_kind not in ('church', 'group') then raise exception 'Choose church or group.'; end if;
  if nm is null or char_length(nm) > 100 then raise exception 'Enter the % name.', case when p_kind = 'church' then 'church' else 'group' end; end if;
  if exists (select 1 from churches where requested_by = me and status = 'pending') then
    raise exception 'You already have a request waiting for approval. We''ll email you as soon as it''s reviewed.';
  end if;
  loop
    v_code := ''; for i in 1..6 loop v_code := v_code || substr(A, 1 + floor(random() * length(A))::int, 1); end loop;
    exit when not exists (select 1 from churches c where c.code = v_code);
  end loop;
  sl := trim(both '-' from regexp_replace(lower(nm), '[^a-z0-9]+', '-', 'g')) || '-' || lower(left(v_code, 3));
  insert into churches (name, city, state, phone, website, code, slug, enrollment_policy, kind, status, requested_by, request_note)
  values (nm, nullif(trim(p_city), ''), nullif(upper(trim(p_state)), ''), nullif(trim(p_phone), ''), nullif(trim(p_website), ''), v_code, sl, 'approval', p_kind, 'pending', me,
          nullif(trim(concat_ws(' · ', nullif(trim(p_role), ''), nullif(trim(p_note), ''))), ''))
  returning id into cid;
  return json_build_object('id', cid, 'status', 'pending');
end $$;

create or replace function public.my_leader_requests() returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object(
    'orgs', (select coalesce(json_agg(json_build_object('name', c.name, 'kind', c.kind, 'status', c.status, 'code', case when c.status = 'active' then c.code end, 'created_at', c.created_at) order by c.created_at desc), '[]'::json)
             from churches c where c.requested_by = private.my_partner_id()),
    'groups', (select coalesce(json_agg(json_build_object('church', c.name, 'group_name', g.group_name, 'status', g.status, 'created_at', g.created_at) order by g.created_at desc), '[]'::json)
               from group_lead_requests g join churches c on c.id = g.church_id where g.partner_id = private.my_partner_id())) $$;

create or replace function public.admin_org_requests() returns table (id uuid, kind text, name text, city text, state text, phone text, website text, note text, requester text, email text, created_at timestamptz, status text)
language sql stable security definer set search_path = public, private as $$
  select c.id, c.kind, c.name, c.city, c.state, c.phone, c.website, c.request_note, p.first_name || ' ' || p.last_name, p.email, c.created_at, c.status
  from churches c left join partners p on p.id = c.requested_by
  where private.is_platform_admin() and c.status = 'pending' order by c.created_at $$;

create or replace function public.admin_decide_org(p_id uuid, p_approve boolean) returns text
language plpgsql security definer set search_path = public, private as $$
declare c churches; p partners;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can approve churches.'; end if;
  select * into c from churches where id = p_id for update;
  if c.id is null or c.status <> 'pending' then raise exception 'That request was not found or was already decided.'; end if;
  select * into p from partners where id = c.requested_by;
  if p_approve then
    update churches set status = 'active', decided_at = now() where id = c.id;
    if p.id is not null then
      insert into role_assignments (user_id, church_id, role, verified_at) values (p.auth_user_id, c.id, 'church_admin', now());
      update memberships set status = 'removed', table_id = null where partner_id = p.id and status <> 'removed' and church_id <> c.id;
      insert into memberships (partner_id, church_id, status, last_active_at) values (p.id, c.id, 'verified', current_date)
        on conflict do nothing;
      perform private.queue_email(p.email, 'Approved: ' || c.name || ' is ready in the 144(P) Plan',
        array['Good news, ' || h(p.first_name) || '! <strong>' || h(c.name) || '</strong> is approved and you are its admin.',
              'Your ' || case when c.kind = 'church' then 'church' else 'group' end || ' code is <strong>' || h(c.code) || '</strong>. Share it with your members, or print the QR sign from the Leader Console.',
              'Next: buy study book seats for your members in the Leader Console (Approvals › Buy seats), then approve people as they join.'],
        'Open the Leader Console', 'https://time4god.app/leader.html', null, 'leader.org_approved');
    end if;
  else
    update churches set status = 'declined', decided_at = now() where id = c.id;
    if p.id is not null then
      perform private.queue_email(p.email, 'About your request for ' || c.name,
        array['Thank you for your interest in the 144(P) Plan, ' || h(p.first_name) || '.', 'We weren''t able to approve <strong>' || h(c.name) || '</strong> right now. Reply to this email and we''ll help you get set up.'],
        null, null, null, 'leader.org_declined');
    end if;
  end if;
  return case when p_approve then 'approved' else 'declined' end;
end $$;

-- ---------- leading a group inside a church ----------
create or replace function public.request_group_lead(p_code text, p_group_name text, p_note text) returns text
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); ch churches; st text;
begin
  if me is null then raise exception 'Create your free account first.'; end if;
  select * into ch from churches where upper(code) = upper(trim(p_code)) and status = 'active';
  if ch.id is null then raise exception 'That church code was not found. Ask your church office for it.'; end if;
  if nullif(trim(p_group_name), '') is null then raise exception 'Enter the name of the group you lead.'; end if;
  -- join the church too (or keep the existing membership)
  st := public.join_church_by_code(p_code);
  insert into group_lead_requests (church_id, partner_id, group_name, note) values (ch.id, me, left(trim(p_group_name), 60), nullif(left(trim(p_note), 300), ''))
  on conflict (church_id, partner_id) where status = 'pending' do update set group_name = excluded.group_name, note = excluded.note;
  return 'pending';
end $$;

create or replace function public.group_lead_requests_for(cid uuid) returns table (id uuid, name text, email text, group_name text, note text, created_at timestamptz, member_status text)
language sql stable security definer set search_path = public, private as $$
  select g.id, p.first_name || ' ' || p.last_name, p.email, g.group_name, g.note, g.created_at,
    (select m.status from memberships m where m.partner_id = g.partner_id and m.church_id = g.church_id and m.status <> 'removed' limit 1)
  from group_lead_requests g join partners p on p.id = g.partner_id
  where g.church_id = cid and g.status = 'pending' and private.manages_church(cid) order by g.created_at $$;

-- p_group: an existing group to lead, or null to create a new group with the requested name
create or replace function public.decide_group_lead(p_id uuid, p_approve boolean, p_group uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare g group_lead_requests; t uuid; p partners; cname text;
begin
  select * into g from group_lead_requests where id = p_id for update;
  if g.id is null or g.status <> 'pending' then raise exception 'That request was not found or was already decided.'; end if;
  if not private.manages_church(g.church_id) then raise exception 'Only the church admin can approve group leaders.'; end if;
  select * into p from partners where id = g.partner_id;
  select name into cname from churches where id = g.church_id;
  if not p_approve then
    update group_lead_requests set status = 'declined', decided_at = now() where id = g.id;
    return 'declined';
  end if;
  update memberships set status = 'verified' where partner_id = g.partner_id and church_id = g.church_id and status = 'pending';
  if p_group is null then
    t := public.save_group(g.church_id, null, g.group_name);
  else
    select id into t from tables where id = p_group and church_id = g.church_id and status = 'active';
    if t is null then raise exception 'That group was not found.'; end if;
  end if;
  perform public.set_group_lead(t, g.partner_id);
  update group_lead_requests set status = 'approved', decided_at = now(), table_id = t where id = g.id;
  perform private.queue_email(p.email, 'You''re a group leader at ' || cname,
    array['<strong>' || h(cname) || '</strong> approved you to lead <strong>' || h((select name from tables where id = t)) || '</strong>.',
          'In the Leader Console you can approve new members, add people to your group, message them and send group challenges.'],
    'Open the Leader Console', 'https://time4god.app/leader.html', null, 'leader.group_approved');
  return 'approved';
end $$;

-- ---------- emails when requests come in ----------
create or replace function private.on_new_church() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare mail text; who text;
begin
  select first_name || ' ' || last_name || ' (' || email || ')' into who from partners where id = new.requested_by;
  for mail in select private.admin_emails() loop
    if new.status = 'pending' then
      perform private.queue_email(mail, 'Approval needed: new ' || new.kind || ' · ' || new.name,
        array['<strong>' || h(coalesce(who, 'Someone')) || '</strong> asked to set up the ' || new.kind || ' <strong>' || h(new.name) || '</strong>' || coalesce(' in ' || h(nullif(concat_ws(', ', new.city, new.state), '')), '') || '.',
              coalesce('Note: ' || h(new.request_note), 'No note added.'),
              'Approve or decline it in Admin Panel › Churches.'],
        'Review the request', 'https://time4god.app/admin.html', null, 'admin.org_request');
    else
      perform private.queue_email(mail, 'New church: ' || new.name,
        array['<strong>' || h(new.name) || '</strong>' || coalesce(' (' || h(nullif(concat_ws(', ', new.city, new.state), '')) || ')', '') || ' was added. Church code: <strong>' || h(new.code) || '</strong>.',
              'Next step: assign its church admin in Admin Panel › Churches.'],
        'Open Churches', 'https://time4god.app/admin.html', null, 'admin.new_church');
    end if;
  end loop;
  return null;
end $$;

create or replace function private.on_group_lead_request() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare a record; p partners; cname text;
begin
  select * into p from partners where id = new.partner_id;
  select name into cname from churches where id = new.church_id;
  for a in select distinct u.email::text em from role_assignments r join auth.users u on u.id = r.user_id
           where r.church_id = new.church_id and r.role = 'church_admin' and r.verified_at is not null and r.revoked_at is null loop
    perform private.queue_email(a.em, 'Group leader request: ' || p.first_name || ' ' || p.last_name,
      array['<strong>' || h(p.first_name || ' ' || p.last_name) || '</strong> (' || h(p.email) || ') asked to lead the group <strong>' || h(new.group_name) || '</strong> at ' || h(cname) || '.',
            coalesce('Note: ' || h(new.note), ''), 'Approve or decline it in the Leader Console › Groups.'],
      'Review the request', 'https://time4god.app/leader.html', null, 'leader.group_request');
  end loop;
  return null;
end $$;
create trigger notify_group_lead_request after insert on public.group_lead_requests for each row execute function private.on_group_lead_request();

-- ---------- grants ----------
do $$ declare f text; begin
  foreach f in array array['request_organization(text, text, text, text, text, text, text, text)', 'my_leader_requests()', 'admin_org_requests()', 'admin_decide_org(uuid, boolean)',
    'request_group_lead(text, text, text)', 'group_lead_requests_for(uuid)', 'decide_group_lead(uuid, boolean, uuid)']
  loop execute format('revoke execute on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;

-- 0014b: the Leader Console lists only approved churches
create or replace function public.my_leader_churches()
returns table (church_id uuid, name text, code text, role text)
language sql stable security definer set search_path = public, private as $$
  select c.id, c.name, c.code, case when private.is_platform_admin() then 'platform_admin' when private.is_church_admin(c.id) then 'church_admin' else 'table_leader' end
  from churches c where c.status = 'active' and private.can_approve(c.id) order by c.name $$;
