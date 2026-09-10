do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_metrics';
  if k = 'm' then execute 'drop materialized view if exists market.pending_metrics cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_metrics cascade';
  end if;
end $$;
create view market.pending_metrics as
SELECT security_id,
    statement,
    period_ending
   FROM market.security_statement st
  WHERE derived_at IS NULL;
