-- 0033: Terms and Conditions and Privacy Policy, editable in Admin Panel › Settings.
-- Public pages terms.html and privacy.html read them. Placeholders filled in when shown:
--   {{support_email}} (Settings › support email), {{mailing_address}} (Settings › invoice mailing address),
--   {{effective_date}} (the date set when saving).
create table if not exists public.legal_docs (
  slug text primary key check (slug in ('terms', 'privacy')),
  title text not null, body text not null, effective_date date not null default current_date,
  version int not null default 1, updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.legal_doc_versions (
  id bigserial primary key, slug text not null, version int not null, title text not null, body text not null,
  effective_date date not null, saved_at timestamptz not null default now(), saved_by uuid
);
alter table public.legal_docs enable row level security;
alter table public.legal_doc_versions enable row level security;
revoke all on public.legal_docs, public.legal_doc_versions from anon, authenticated;

-- Version 1 of both pages was loaded from legal/terms.md and legal/privacy.md (published with the site)
-- with pg_net, checked by md5, then inserted into legal_docs and legal_doc_versions.

-- Anyone (signed in or not) can read the published text, with placeholders filled in
create or replace function public.public_legal(p_slug text) returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object('slug', d.slug, 'title', d.title, 'version', d.version, 'effective_date', d.effective_date, 'updated_at', d.updated_at,
    'body', replace(replace(replace(d.body,
      '{{support_email}}', coalesce(private.setting('support_email'), 'support@time4god.app')),
      '{{mailing_address}}', coalesce(replace(private.setting('invoice_address'), E'\n', ', '), 'Georgia, United States')),
      '{{effective_date}}', to_char(d.effective_date, 'FMMonth FMDD, YYYY')))
  from legal_docs d where d.slug = p_slug $$;

create or replace function public.admin_legal_docs() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can edit legal pages.'; end if;
  return (select json_agg(json_build_object('slug', d.slug, 'title', d.title, 'body', d.body, 'effective_date', d.effective_date, 'version', d.version,
      'updated_at', d.updated_at, 'versions', (select count(*) from legal_doc_versions v where v.slug = d.slug)) order by d.slug desc) from legal_docs d);
end $$;

-- Saving keeps every earlier version, so nothing is ever lost
create or replace function public.admin_save_legal(p_slug text, p_title text, p_body text, p_effective date) returns json
language plpgsql security definer set search_path = public, private as $$
declare d legal_docs;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can edit legal pages.'; end if;
  if coalesce(length(trim(p_body)), 0) < 200 then raise exception 'That text looks too short. Nothing was saved.'; end if;
  update legal_docs set title = coalesce(nullif(trim(p_title), ''), title), body = p_body, effective_date = coalesce(p_effective, current_date),
    version = version + 1, updated_at = now(), updated_by = auth.uid()
  where slug = p_slug returning * into d;
  if d.slug is null then raise exception 'Unknown page.'; end if;
  insert into legal_doc_versions (slug, version, title, body, effective_date, saved_by) values (d.slug, d.version, d.title, d.body, d.effective_date, auth.uid());
  return json_build_object('version', d.version, 'effective_date', d.effective_date);
end $$;

create or replace function public.admin_legal_versions(p_slug text) returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see this.'; end if;
  return (select coalesce(json_agg(json_build_object('id', v.id, 'version', v.version, 'effective_date', v.effective_date, 'saved_at', v.saved_at, 'body', v.body) order by v.version desc), '[]'::json)
    from legal_doc_versions v where v.slug = p_slug);
end $$;

revoke execute on function public.public_legal(text), public.admin_legal_docs(), public.admin_save_legal(text, text, text, date), public.admin_legal_versions(text) from public;
grant execute on function public.public_legal(text) to anon, authenticated;
grant execute on function public.admin_legal_docs(), public.admin_save_legal(text, text, text, date), public.admin_legal_versions(text) to authenticated;
