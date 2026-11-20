-- 0016b: printed-book readers get a seat to give too. Unlocking the app with a book key
-- adds one guest seat (one per reader per book key; there's no payment behind it).
alter table public.guest_passes add column if not exists key_id uuid references public.book_keys(id) on delete set null;
create unique index if not exists guest_passes_owner_key on public.guest_passes (owner_partner_id, key_id) where key_id is not null;

create or replace function public.redeem_answer(p_question uuid, p_answer text) returns json
language plpgsql security definer set search_path = public, private as $$
declare me uuid := private.my_partner_id(); q key_questions; s seasons; ip uuid;
begin
  select * into q from key_questions where id = p_question and partner_id = me for update;
  if q.id is null then raise exception 'Question not found. Start again.'; end if;
  if q.solved_at is not null then return json_build_object('status', 'ok'); end if;
  if q.expires_at < now() or q.wrong >= 3 then raise exception 'This question has expired. Get a new one.'; end if;
  if norm_word(p_answer) <> q.answer then
    update key_questions set wrong = wrong + 1 where id = q.id;
    return json_build_object('status', case when q.wrong + 1 >= 3 then 'locked' else 'wrong' end, 'left', greatest(0, 2 - q.wrong));
  end if;
  select * into s from seasons where active limit 1;
  select id into ip from license_plans where kind = 'individual' order by sort_order limit 1;
  insert into individual_seats (partner_id, season_id, plan_id, price, status, paid_at, expires_at)
  values (me, s.id, ip, 0, 'active', now(), now() + interval '1 year')
  on conflict (partner_id, season_id) do update set status = 'active', price = 0, paid_at = now(), expires_at = now() + interval '1 year';
  insert into key_claims (key_id, partner_id, page) values (q.key_id, me, q.page) on conflict do nothing;
  -- Give one: the printed book includes a seat to give, like an app purchase
  insert into guest_passes (owner_partner_id, key_id) values (me, q.key_id) on conflict do nothing;
  update key_questions set solved_at = now() where id = q.id;
  insert into audit_logs (actor_id, action, resource_type, resource_id, metadata)
    values (auth.uid(), 'book_key.claimed', 'book_key', q.key_id::text, jsonb_build_object('page', q.page));
  return json_build_object('status', 'ok');
end $$;

-- Readers who already used a book key get their seat to give now
insert into guest_passes (owner_partner_id, key_id)
select distinct partner_id, key_id from key_claims
on conflict do nothing;
