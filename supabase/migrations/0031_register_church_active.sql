-- 0031: the sign-up page can also update an approved church that hasn't bought seats yet (no duplicate church).
do $$
declare d text;
begin
  d := pg_get_functiondef('public.register_church(text,text,text,text,text,text,text,text,text,text,text,text)'::regprocedure);
  d := replace(d, $q$select * into c from churches where requested_by = me and status = 'pending' order by created_at desc limit 1;$q$,
                  $q$select * into c from churches where requested_by = me and status in ('pending', 'active') order by created_at desc limit 1;$q$);
  if position($q$status in ('pending', 'active') order by$q$ in d) = 0 then raise exception 'register_church not updated'; end if;
  execute d;
end $$;
