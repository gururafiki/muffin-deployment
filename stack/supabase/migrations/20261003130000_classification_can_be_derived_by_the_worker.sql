-- The Dagster worker may derive classifications (Phase 3 stage 5, expand).
--
-- WHY. `derive-classifications` has failed every daily run since 2026-09-27:
-- `derive_segment_classification failed: canceling statement due to statement timeout`. It is
-- called through PostgREST, whose role stops a statement at 8 s. Measured on production
-- 2026-10-03 in a rolled-back transaction: `derive_classifications` 5.2 s, `derive_sic_classification`
-- 52 ms, `derive_segment_classification` 20.1 s. From Dagster the same calls run as `ingest_rw`,
-- whose statement timeout is 120 s, which is what Stage 5 of the umbrella's
-- docs/specs/2026-09-26-finishing-the-universe-family.md moves them to.
--
-- All three are SECURITY DEFINER with EXECUTE held by `service_role` alone, so `ingest_rw` gets
-- `permission denied for function derive_classifications` today (measured). The grant is additive:
-- the edge resource keeps working until its retirement lands, after the asset has run live.
-- `anon` stays without EXECUTE; these functions rewrite `security_taxonomy`.

grant execute on function
  market.derive_classifications(),
  market.derive_segment_classification(),
  market.derive_sic_classification()
to ingest_rw;
