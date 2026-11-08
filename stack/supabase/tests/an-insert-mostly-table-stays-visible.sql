-- AN INSERT-MOSTLY TABLE VACUUMS ON ITS OWN INSERTS, OR ITS INDEX-ONLY SCANS READ THE HEAP.
-- Migration 20261108130000.
--
-- WHY THIS EXISTS. On 2026-11-07 the insider history took `market.insider_trade` from 0.75 M to
-- 5.52 M rows. Autovacuum's default insert trigger is `1000 + 0.2 * reltuples`, so after the load
-- 926,730 rows sat with no visibility-map bits and the next vacuum was months away. Every
-- index-only scan of the table then read the heap for each of them; `coverage_current`'s
-- `select distinct security_id from market.insider_trade` spent 33 s there, and the coverage sample
-- was cancelled at its 120 s bound on 11-08.
--
-- A table's storage options are not part of any view or function, so the schemas/ bundle does not
-- carry them: only the migration does, and a database rebuilt from the repo must still have it.

\set ON_ERROR_STOP on

do $$
declare
  factor text;
begin
  select option_value into factor
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral pg_options_to_table(c.reloptions)
   where n.nspname = 'market' and c.relname = 'insider_trade'
     and option_name = 'autovacuum_vacuum_insert_scale_factor';
  if factor is null then
    raise exception 'market.insider_trade carries no autovacuum_vacuum_insert_scale_factor: on the '
                    'default 0.2 a bulk load leaves its index-only scans reading the heap for months';
  end if;
  if factor::numeric > 0.05 then
    raise exception 'market.insider_trade vacuums after % of its rows are new inserts; at 5.5 M rows '
                    'anything above 0.05 waits for ~275,000 rows, months of the daily Form 4 lane', factor;
  end if;
  raise notice 'ok  insider_trade vacuums after % of its rows are new inserts', factor;
end $$;
