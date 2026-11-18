-- 0005: the platform admin can remove a book section from the app.
-- Removed sections stay out after a new Word upload (the upload never changes "hidden").
alter table public.book_sections add column if not exists hidden boolean not null default false;

drop policy if exists book_select on public.book_sections;
create policy book_select on public.book_sections for select to authenticated
  using ((select private.is_platform_admin()) or (not hidden and unlock_week <= (select private.my_unlocked_week())));

create or replace function public.book_toc()
returns table (slug text, title text, kind text, unlock_week int, sort_order int)
language sql stable security definer set search_path = public as $$
  select slug, title, kind, unlock_week, sort_order from book_sections where not hidden order by sort_order $$;
