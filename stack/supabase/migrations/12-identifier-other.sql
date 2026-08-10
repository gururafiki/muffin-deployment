-- One more identifier kind, for the keys N-PORT reports under `<other otherDesc="…">`.
--
-- Measured over five funds on 2026-08-10: 233 of 308 holdings carry an `<other>` identifier, and
-- for a derivative row (a futures contract, which has no ISIN and no CUSIP) it is the ONLY key
-- available. Without somewhere to put it those rows cannot be resolved on a re-run, so each
-- ingest would create them again — the ingest would stop being idempotent.
--
-- `is_global_unique = false`: unlike an ISIN, "whatever the filer chose to put in otherDesc" is
-- not a namespace anyone guarantees.

insert into market.identifier_kind (code, name, is_global_unique) values
  ('other', 'Other (filer-supplied)', false)
on conflict (code) do update set name = excluded.name, is_global_unique = excluded.is_global_unique;

-- FM stopped filing: its last NPORT-P covers 2024-11-30 (the fund was reorganised away). It is the
-- ONE fund of 39 that a full pass cannot ingest, and leaving it enabled means every monthly run
-- reports a failure that will never clear.
--
-- `where notes is null` so this never reverts a human edit — tracked_fund is the control surface,
-- and re-enabling it in Studio (with a note) must win over a redeploy.
update market.tracked_fund
   set enabled = false,
       notes = 'No NPORT-P since 2024-11-30 — fund reorganised away. Re-enable if it resumes filing.'
 where symbol = 'FM' and notes is null;

notify pgrst, 'reload schema';
