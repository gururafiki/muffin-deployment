do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_fx_history';
  if k = 'm' then execute 'drop materialized view if exists market.pending_fx_history cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_fx_history cascade';
  end if;
end $$;
create view market.pending_fx_history as
SELECT code AS currency_code
   FROM market.currency c
  WHERE code <> 'USD'::text AND (history_missing_at IS NULL OR history_missing_at < (now() - '30 days'::interval)) AND NOT (EXISTS ( SELECT 1
           FROM market.fx_rate r
          WHERE r.currency_code = c.code AND r.as_of < (CURRENT_DATE - 90)));
