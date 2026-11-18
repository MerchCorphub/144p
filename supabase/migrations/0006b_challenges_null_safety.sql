-- 0006b: a signed-in account with no partner record must never pass a "sent by me" check
-- (NULL = NULL is not true, but NOT (NULL OR false) let it through).
create or replace function private.can_see_challenge(c public.challenges)
returns boolean language sql stable security definer set search_path = public, private as $$
  select coalesce(c.created_by = private.my_partner_id(), false)
    or private.my_challenge_side(c) is not null
    or coalesce(private.is_church_admin(private.side_church(c, 1)), false)
    or coalesce(private.is_church_admin(private.side_church(c, 2)), false)
    or (c.kind = 'church_open' and exists (select 1 from memberships m where m.partner_id = private.my_partner_id() and m.church_id = c.a_church and m.status = 'verified')) $$;

create or replace function public.cancel_challenge(p_id uuid)
returns void language plpgsql security definer set search_path = public, private as $$
declare c challenges;
begin
  select * into c from challenges where id = p_id;
  if c.id is null or not (coalesce(c.created_by = private.my_partner_id(), false)
      or (c.kind = 'church_open' and coalesce(private.is_church_admin(c.a_church), false))
      or private.is_platform_admin()) then
    raise exception 'Only the person who sent this challenge can cancel it.';
  end if;
  if c.status = 'pending' or (c.kind = 'church_open' and c.status = 'active') then
    update challenges set status = 'canceled' where id = p_id;
  else
    raise exception 'Only a challenge that hasn''t been accepted yet can be canceled.';
  end if;
end $$;

create or replace function public.challenge_board(p_id uuid)
returns json language plpgsql stable security definer set search_path = public, private as $$
declare c challenges;
begin
  select * into c from challenges where id = p_id;
  if c.id is null or not (coalesce(private.can_see_challenge(c), false) or private.is_platform_admin()) then raise exception 'That challenge was not found.'; end if;
  if c.kind = 'church_open' then
    return (select coalesce(json_agg(r order by r.total desc, r.name), '[]'::json) from (
      select p.first_name || coalesce(' ' || nullif(left(p.last_name, 1), '') || '.', '') as name, coalesce(e.partner_id = private.my_partner_id(), false) as me,
        coalesce((select sum(d.minutes) from time_deposits d where d.partner_id = e.partner_id and d.voided_at is null
          and d.activity_date between c.start_date and least(c.end_date, current_date)), 0)::int as total
      from challenge_entrants e join partners p on p.id = e.partner_id where e.challenge_id = c.id) r);
  end if;
  if c.kind = 'person' and c.status = 'active' and current_date between c.start_date and c.end_date then
    return (select coalesce(json_agg(r order by r.day desc), '[]'::json) from (
      select d.activity_date as day,
        sum(d.minutes) filter (where d.partner_id = c.a_partner)::int as a,
        sum(d.minutes) filter (where d.partner_id = c.b_partner)::int as b
      from time_deposits d where d.partner_id in (c.a_partner, c.b_partner) and d.voided_at is null
        and d.activity_date between c.start_date and current_date
      group by d.activity_date) r);
  end if;
  return '[]'::json;
end $$;

create or replace function private.challenge_row(c public.challenges)
returns json language sql stable security definer set search_path = public, private as $$
  select json_build_object('id', c.id, 'kind', c.kind, 'status', c.status, 'title', c.title, 'message', c.message,
    'start_date', c.start_date, 'end_date', c.end_date, 'created_at', c.created_at,
    'phase', case when c.status <> 'active' then c.status when current_date < c.start_date then 'upcoming' when current_date > c.end_date then 'finished' else 'live' end,
    'a_name', private.challenge_side_name(c, 1), 'b_name', private.challenge_side_name(c, 2),
    'a', (select row_to_json(x) from private.challenge_stats(c, 1) x),
    'b', case when c.kind <> 'church_open' and c.status = 'active' then (select row_to_json(x) from private.challenge_stats(c, 2) x) end,
    'my_side', private.my_challenge_side(c),
    'is_sender', coalesce(c.created_by = private.my_partner_id(), false),
    'invite_code', case when coalesce(c.created_by = private.my_partner_id(), false) and c.status = 'pending' then c.invite_code end,
    'can_manage', coalesce(c.created_by = private.my_partner_id(), false) or (c.kind = 'church_open' and coalesce(private.is_church_admin(c.a_church), false))) $$;

revoke execute on function public.cancel_challenge(uuid), public.challenge_board(uuid) from public, anon;
grant execute on function public.cancel_challenge(uuid), public.challenge_board(uuid) to authenticated;
revoke execute on function private.can_see_challenge(public.challenges), private.challenge_row(public.challenges) from public, anon;
grant execute on function private.can_see_challenge(public.challenges), private.challenge_row(public.challenges) to authenticated;
