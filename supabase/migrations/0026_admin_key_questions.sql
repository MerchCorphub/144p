-- 0026: Admin Panel › Book keys shows the page question each reader was asked: the page, the
-- word shown, the word they had to type next, and the line it comes from (so the admin can
-- help a reader who is stuck).
create or replace function public.admin_key_questions()
returns table (id uuid, created_at timestamptz, name text, email text, code text, page int, word text, answer text, context text,
               wrong int, status text, solved_at timestamptz)
language sql stable security definer set search_path = public, private as $$
  select q.id, q.created_at, p.first_name || ' ' || p.last_name, p.email, k.code, q.page, q.anchor,
    coalesce(private.clean_word(x.words[x.i + 1]), q.answer),
    case when x.i is not null then array_to_string(x.words[greatest(1, x.i - 6):x.i + 8], ' ') end,
    q.wrong,
    case when q.solved_at is not null then 'claimed' when q.wrong >= 3 then 'locked' when q.expires_at < now() then 'expired' else 'waiting' end,
    q.solved_at
  from key_questions q join partners p on p.id = q.partner_id join book_keys k on k.id = q.key_id
  left join lateral (
    select pp.words, (select min(j) from generate_subscripts(pp.words, 1) j
                      where private.clean_word(pp.words[j]) = q.anchor and private.norm_word(pp.words[j + 1]) = q.answer) i
    from print_pages pp where pp.page = q.page) x on true
  where private.is_platform_admin()
  order by q.created_at desc limit 200 $$;

revoke execute on function public.admin_key_questions() from public, anon;
grant execute on function public.admin_key_questions() to authenticated;
