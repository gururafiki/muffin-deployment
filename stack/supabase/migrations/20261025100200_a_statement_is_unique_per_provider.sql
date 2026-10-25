-- A STATEMENT IS UNIQUE PER PROVIDER: the key step 2b swaps in, built beside the current one.
-- Phase 5 step 2a of the umbrella's docs/specs/2026-10-24-sec-family.md (decision 6).
--
-- Today's key, `(security_id, statement, period_ending, period_type)`, holds ONE provider's row per
-- period, which is why the Yahoo writer guards with `only_replacing` and why a SEC row and a Yahoo
-- row for one period cannot both be kept. Decision 6 puts the provider in the key, and every
-- serving view then picks by `source_priority`.
--
-- Built here so the swap in step 2b is `add primary key using index`, a catalogue change, rather
-- than an index build in the middle of the window that changes the writers. Every row that
-- satisfies the current key satisfies this one, so the build cannot fail on production's data.
--
-- ITS OWN MIGRATION, so its own transaction: the build takes a SHARE lock (writes wait, reads do
-- not), and in the previous file it would have been held under that file's ACCESS EXCLUSIVE lock,
-- which blocks the app's statement reads. Measured on production 2026-10-25, rolled back: see the
-- umbrella spec's As built.

create unique index if not exists security_statement_provider_key
  on market.security_statement (security_id, source_code, statement, period_ending, period_type);
