-- 0030: an invoice with no billing email is still drawn, and stops waiting to be emailed.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.invoice_job_done(uuid,text,boolean)'::regprocedure);
  d := replace(d, 'if not p_emailed or not d.email_pending then return; end if;',
    'if d.email_pending and d.bill_to_email is null then update invoice_docs set email_pending = false where id = d.id; return; end if;
  if not p_emailed or not d.email_pending then return; end if;');
  if position('bill_to_email is null' in d) = 0 then raise exception 'invoice_job_done not updated'; end if;
  execute d;
end $$;
