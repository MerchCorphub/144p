-- 0039: Bookstore. Admins list books for sale with buy links (Amazon, IngramSpark Share & Sell, others).
-- Amazon / IngramSpark take the order, print and ship. The app only shows the books and counts clicks.

create table if not exists public.store_books (
  id uuid primary key default gen_random_uuid(),
  title text not null, subtitle text, author text not null default 'C.P. Parker', description text,
  cover_url text, price_label text,
  links jsonb not null default '[]'::jsonb,   -- [{label, url}]
  active boolean not null default true, featured boolean not null default false, sort_order int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.store_clicks (
  id bigserial primary key, book_id uuid references public.store_books(id) on delete cascade, label text, partner_id uuid, at timestamptz not null default now()
);
create index if not exists store_clicks_book on public.store_clicks (book_id, at);
alter table public.store_books enable row level security;
alter table public.store_clicks enable row level security;
revoke all on public.store_books, public.store_clicks from anon, authenticated;

-- Cover pictures: public bucket; only the platform admin can upload
insert into storage.buckets (id, name, public) values ('covers', 'covers', true) on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'covers_admin_insert') then
    create policy covers_admin_insert on storage.objects for insert to authenticated with check (bucket_id = 'covers' and private.is_platform_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'covers_admin_update') then
    create policy covers_admin_update on storage.objects for update to authenticated using (bucket_id = 'covers' and private.is_platform_admin());
  end if;
end $$;

create or replace function public.store_books_public() returns json
language sql stable security definer set search_path = public, private as $$
  select coalesce(json_agg(json_build_object('id', b.id, 'title', b.title, 'subtitle', b.subtitle, 'author', b.author, 'description', b.description,
      'cover_url', b.cover_url, 'price_label', b.price_label, 'links', b.links, 'featured', b.featured)
    order by b.featured desc, b.sort_order, b.created_at), '[]'::json)
  from store_books b where b.active $$;

create or replace function public.store_click(p_book uuid, p_label text) returns void
language sql security definer set search_path = public, private as $$
  insert into store_clicks (book_id, label, partner_id)
  select id, left(p_label, 60), private.my_partner_id() from store_books where id = p_book and active $$;

create or replace function public.admin_store_books() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see this.'; end if;
  return (select coalesce(json_agg(json_build_object('id', b.id, 'title', b.title, 'subtitle', b.subtitle, 'author', b.author, 'description', b.description,
      'cover_url', b.cover_url, 'price_label', b.price_label, 'links', b.links, 'active', b.active, 'featured', b.featured, 'sort_order', b.sort_order,
      'clicks_30', (select count(*) from store_clicks c where c.book_id = b.id and c.at > now() - interval '30 days'),
      'clicks_all', (select count(*) from store_clicks c where c.book_id = b.id),
      'by_link', (select coalesce(json_object_agg(label, n), '{}'::json) from (select label, count(*) n from store_clicks c where c.book_id = b.id group by label) x))
    order by b.active desc, b.featured desc, b.sort_order, b.created_at), '[]'::json) from store_books b);
end $$;

create or replace function public.admin_save_store_book(p_id uuid, p_title text, p_subtitle text, p_author text, p_description text, p_cover_url text,
  p_price_label text, p_links jsonb, p_active boolean, p_featured boolean, p_sort int) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare bid uuid; l jsonb; clean jsonb := '[]'::jsonb;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can change the bookstore.'; end if;
  if nullif(trim(p_title), '') is null then raise exception 'Give the book a title.'; end if;
  if nullif(trim(p_cover_url), '') is not null and trim(p_cover_url) !~ '^https://' then raise exception 'The cover picture link must start with https://'; end if;
  for l in select * from jsonb_array_elements(coalesce(p_links, '[]'::jsonb)) loop
    if nullif(trim(l->>'url'), '') is null then continue; end if;
    if trim(l->>'url') !~ '^https://' then raise exception 'Buy links must start with https:// (check "%").', coalesce(l->>'label', 'link'); end if;
    clean := clean || jsonb_build_array(jsonb_build_object('label', coalesce(nullif(trim(l->>'label'), ''), 'Buy now'), 'url', trim(l->>'url')));
  end loop;
  if p_id is null then
    insert into store_books (title, subtitle, author, description, cover_url, price_label, links, active, featured, sort_order)
    values (trim(p_title), nullif(trim(p_subtitle), ''), coalesce(nullif(trim(p_author), ''), 'C.P. Parker'), nullif(trim(p_description), ''),
            nullif(trim(p_cover_url), ''), nullif(trim(p_price_label), ''), clean, coalesce(p_active, true), coalesce(p_featured, false), coalesce(p_sort, 0))
    returning id into bid;
  else
    update store_books set title = trim(p_title), subtitle = nullif(trim(p_subtitle), ''), author = coalesce(nullif(trim(p_author), ''), 'C.P. Parker'),
      description = nullif(trim(p_description), ''), cover_url = nullif(trim(p_cover_url), ''), price_label = nullif(trim(p_price_label), ''),
      links = clean, active = coalesce(p_active, active), featured = coalesce(p_featured, featured), sort_order = coalesce(p_sort, sort_order), updated_at = now()
    where id = p_id returning id into bid;
    if bid is null then raise exception 'Book not found.'; end if;
  end if;
  return bid;
end $$;

revoke execute on function public.store_books_public(), public.store_click(uuid, text) from public;
grant execute on function public.store_books_public(), public.store_click(uuid, text) to anon, authenticated;
revoke execute on function public.admin_store_books(), public.admin_save_store_book(uuid, text, text, text, text, text, text, jsonb, boolean, boolean, int) from public, anon;
grant execute on function public.admin_store_books(), public.admin_save_store_book(uuid, text, text, text, text, text, text, jsonb, boolean, boolean, int) to authenticated;
