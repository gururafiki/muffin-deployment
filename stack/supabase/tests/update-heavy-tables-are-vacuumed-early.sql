-- The update-heavy `market` tables carry a 2% autovacuum threshold (migration 20261123110000), and
-- `insider_trade` its 1% insert threshold (20261108130000).
--
-- WHY THIS EXISTS AS A TEST: a storage parameter lives on the table, so any later migration that
-- recreates or swaps a table drops it silently, and the only symptom is a sample that slows down
-- for weeks (an index-only scan paying 610,736 heap fetches on `security_filing`, 2026-11-23).

\set ON_ERROR_STOP on

do $$
declare
  missing text;
begin
  select string_agg(t, ', ' order by t) into missing
    from unnest(array['security_filing', 'security_metric', 'security_segment',
                      'security_statement', 'fiscal_period']) t
   where not exists (
     select 1 from pg_class c
      where c.oid = ('market.' || t)::regclass
        and 'autovacuum_vacuum_scale_factor=0.02' = any(c.reloptions)
        and 'autovacuum_vacuum_insert_scale_factor=0.02' = any(c.reloptions));
  if missing is not null then
    raise exception 'these update-heavy tables lost their 2%% autovacuum thresholds: %', missing;
  end if;
  if not exists (select 1 from pg_class
                  where oid = 'market.insider_trade'::regclass
                    and 'autovacuum_vacuum_insert_scale_factor=0.01' = any(reloptions)) then
    raise exception 'insider_trade lost its 1%% insert threshold';
  end if;
end $$;

\echo ok update-heavy-tables-are-vacuumed-early
