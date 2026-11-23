-- 0032: saving invoice details redraws open invoices; the approval email fits churches that already paid.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.admin_save_invoice_settings(text,text,text,text)'::regprocedure);
  d := replace(d, 'on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by;',
    'on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by;
  update invoice_docs set pdf_dirty = true where status = ''open'';');
  if position('pdf_dirty = true' in d) = 0 then raise exception 'settings not updated'; end if;
  execute d;
  d := pg_get_functiondef('public.admin_decide_org(uuid,boolean)'::regprocedure);
  d := replace(d, $q$'Next: buy study book seats for your members in the Leader Console (Approvals › Buy seats), then approve people as they join.'$q$,
    $q$case when exists (select 1 from private.current_church_license(c.id) l where l.status = 'active') then 'Your seats are ready. Approve people in the Leader Console as they join with your code.' else 'Next: buy study book seats for your members in the Leader Console (Approvals › Buy seats), then approve people as they join.' end$q$);
  if position('Your seats are ready' in d) = 0 then raise exception 'decide_org not updated'; end if;
  execute d;
end $$;
