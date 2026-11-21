-- 0021: account managers get a Bcc copy of their churches' leader emails
-- (new requests to join / new members, and group leader requests).
-- One Bcc copy per event, on the first email sent to the church's leaders. If the church has no
-- leader to email yet, the account managers get it directly instead.
alter table public.email_outbox add column if not exists bcc text[];

create or replace function private.church_am_emails(cid uuid, p_skip uuid default null) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct u.email::text), '{}') from role_assignments r join auth.users u on u.id = r.user_id
  left join notification_settings n on n.user_id = r.user_id
  where r.church_id = cid and r.role = 'account_manager' and r.verified_at is not null and r.revoked_at is null
    and coalesce(n.email_new_members, true) and r.user_id is distinct from p_skip $$;

-- After a trigger queued leader emails (ids above p_before, of kind p_kind), put the account
-- managers on Bcc of the first one. Returns false when nothing was queued.
create or replace function private.bcc_first(p_before bigint, p_kind text, p_ams text[]) returns boolean
language plpgsql security definer set search_path = public as $$
declare first_id bigint; first_to text;
begin
  select id, to_email into first_id, first_to from email_outbox where id > p_before and kind = p_kind order by id limit 1;
  if first_id is null then return false; end if;
  if coalesce(array_length(p_ams, 1), 0) > 0 then
    update email_outbox set bcc = (select array_agg(x) from unnest(p_ams) x where lower(x) <> lower(first_to)
                                   and not exists (select 1 from email_outbox o where o.id > p_before and o.kind = p_kind and lower(o.to_email) = lower(x)))
    where id = first_id;
  end if;
  return true;
end $$;

create or replace function private.on_join_request() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare p partners; c churches; a record; mail text; who text; verb text; before_id bigint; ams text[]; subj text; lines text[]; btn text;
begin
  if tg_op = 'UPDATE' and new.church_id = old.church_id and not (new.status = 'pending' and old.status <> 'pending') then return null; end if;
  if new.status not in ('pending', 'verified') then return null; end if;
  select * into p from partners where id = new.partner_id;
  select * into c from churches where id = new.church_id;
  who := p.first_name || ' ' || p.last_name;
  verb := case when new.status = 'pending' then 'asked to join' else 'joined' end;
  subj := case when new.status = 'pending' then 'New request to join ' || c.name || ': ' || who else who || ' joined ' || c.name end;
  lines := array['<strong>' || h(who) || '</strong> (' || h(p.email) || ') ' || verb || ' <strong>' || h(c.name) || '</strong> in the 144(P) Plan.',
            case when new.status = 'pending' then 'Please approve them in the Leader Console so they can read the book and join the Time4God Challenge.'
                 else 'No approval is needed. You can place them in a group in the Leader Console.' end];
  btn := case when new.status = 'pending' then 'Review and approve' else 'Open the Leader Console' end;
  select coalesce(max(id), 0) into before_id from email_outbox;
  ams := private.church_am_emails(new.church_id, p.auth_user_id);
  for a in select distinct u.email::text as em from role_assignments r join auth.users u on u.id = r.user_id
           left join notification_settings n on n.user_id = r.user_id
           where r.church_id = new.church_id and r.role in ('church_admin', 'table_leader') and r.verified_at is not null and r.revoked_at is null
             and coalesce(n.email_new_members, true) and r.user_id <> p.auth_user_id loop
    perform private.queue_email(a.em, subj, lines, btn, 'https://time4god.app/leader.html',
      'You get this because you lead ' || h(c.name) || '. To stop these emails, open the Leader Console and turn off "Email me about new members."',
      'leader.join_request');
  end loop;
  if not private.bcc_first(before_id, 'leader.join_request', ams) then
    foreach mail in array ams loop
      perform private.queue_email(mail, subj, lines, btn, 'https://time4god.app/leader.html',
        'You get this because you are the account manager for ' || h(c.name) || '.', 'leader.join_request');
    end loop;
  end if;
  for mail in select private.admin_emails() loop
    perform private.queue_email(mail, 'Join request: ' || who || ' → ' || c.name,
      array['<strong>' || h(who) || '</strong> (' || h(p.email) || ') ' || verb || ' <strong>' || h(c.name) || '</strong>.'],
      'Open the Admin Panel', 'https://time4god.app/admin.html', null, 'admin.join_request');
  end loop;
  return null;
end $$;

create or replace function private.on_group_lead_request() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare a record; p partners; cname text; before_id bigint; ams text[]; mail text; subj text; lines text[];
begin
  select * into p from partners where id = new.partner_id;
  select name into cname from churches where id = new.church_id;
  subj := 'Group leader request: ' || p.first_name || ' ' || p.last_name;
  lines := array['<strong>' || h(p.first_name || ' ' || p.last_name) || '</strong> (' || h(p.email) || ') asked to lead the group <strong>' || h(new.group_name) || '</strong> at ' || h(cname) || '.',
            coalesce('Note: ' || h(new.note), ''), 'Approve or decline it in the Leader Console › Groups.'];
  select coalesce(max(id), 0) into before_id from email_outbox;
  ams := private.church_am_emails(new.church_id, p.auth_user_id);
  for a in select distinct u.email::text em from role_assignments r join auth.users u on u.id = r.user_id
           where r.church_id = new.church_id and r.role = 'church_admin' and r.verified_at is not null and r.revoked_at is null loop
    perform private.queue_email(a.em, subj, lines, 'Review the request', 'https://time4god.app/leader.html', null, 'leader.group_request');
  end loop;
  if not private.bcc_first(before_id, 'leader.group_request', ams) then
    foreach mail in array ams loop
      perform private.queue_email(mail, subj, lines, 'Review the request', 'https://time4god.app/leader.html', null, 'leader.group_request');
    end loop;
  end if;
  return null;
end $$;

revoke execute on function private.church_am_emails(uuid, uuid), private.bcc_first(bigint, text, text[]) from public, anon, authenticated;
