-- The Dagster worker can derive classifications, and the public roles cannot. Migration
-- 20261003130000.
--
-- WHY THIS EXISTS. The derivation moved off PostgREST because its 8 s ceiling cancelled
-- `derive_segment_classification` every day from 2026-09-27. If `ingest_rw` lost EXECUTE, the
-- Dagster asset would fail exactly as the edge resource did, so the call is made as that role
-- here rather than only asserted from the catalogue.

\set ON_ERROR_STOP on

begin;

do $$
declare
  f text;
begin
  foreach f in array array['market.derive_classifications()',
                           'market.derive_segment_classification()',
                           'market.derive_sic_classification()'] loop
    if not has_function_privilege('ingest_rw', f, 'execute') then
      raise exception 'ingest_rw cannot execute %', f;
    end if;
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception '% is executable by a public role', f;
    end if;
  end loop;
end $$;

set local role ingest_rw;
select market.derive_classifications();
select market.derive_segment_classification();
select market.derive_sic_classification();
reset role;

do $$ begin
  raise notice 'ok  ingest_rw can derive classifications and the public roles cannot';
end $$;

rollback;
