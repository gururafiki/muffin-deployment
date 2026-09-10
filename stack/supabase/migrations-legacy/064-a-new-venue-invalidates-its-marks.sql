-- CORRECTED. The diagnosis this migration originally carried was WRONG, and the measurement that
-- disproved it is below. The statement is kept because it is harmless and mildly useful; the
-- reasoning is rewritten because a comment asserting a false cause is worse than no comment.
--
-- WHAT I CLAIMED. Migration 63 added Ho Chi Minh, Hanoi, Kuwait, Doha and Buenos Aires so their
-- securities could resolve a symbol. Sweeping them worked at once — VN 1,617, VM 409, KK 145,
-- QD 56, AR 213, every count matching what `/v3/filter` predicted — and the securities were still
-- symbol-less. `security-local-symbols` answered `remaining: 0, "no addressable securities
-- pending"`, and 38 of 40 Kuwaiti, 33 of 35 Qatari and 57 of 57 Vietnamese equities carried
-- `figi_missing_at`. I concluded the negative cache was blocking resolution — the Taiwan pattern,
-- where a mark memorises your own bug — and wrote this to clear it.
--
-- WHAT ACTUALLY HAPPENED. The cron ran `security-yahoo-symbols` and `security-local-symbols`
-- twenty minutes later and resolved them: Kuwait 37 of 39, Qatar 33 of 35, Vietnam 56 of 57 now
-- carry a symbol. Measured after that run, `figi_missing_at` was **unchanged** — still 38, 33 and
-- 57. The marks were never cleared and the symbols arrived anyway, which is only possible if the
-- marks were never the blocker.
--
-- THE REAL CAUSE was simply that no resolver had run since the venues appeared. `security-tickers`
-- and `security-local-symbols` read different backlogs: `figi_missing_at` gates the FIGI lookup
-- (`pending_ticker`), and `pending_local_symbol` — which is what actually assigns `SHIP.KW` — does
-- not consult it. My `remaining: 0` reading was taken in the minutes between the sweep finishing
-- and the backlog picking the securities up, and I read a timing gap as a permanent exclusion.
--
-- AND `figi_missing_at` IS LARGELY CORRECT WHERE IT IS SET. It records that OpenFIGI has no US
-- line for an ISIN, which for a local Chinese, Indian, Korean or Kuwaiti listing is simply true —
-- CLAUDE.md says so directly ("ticker resolution asks OpenFIGI for the US line, so ~80% of a Japan
-- or emerging-markets fund can never resolve"). Measured across the universe: CN 96%, IN 99%,
-- TW 96%, KR 97% of equities carry it, and nearly all of those have a working symbol regardless.
-- A high rate is the expected shape of an emerging market, not a defect — which is why the version
-- of this file that treated it as one was reaching for the wrong lever.
--
-- WHY IT STILL RUNS. Clearing the flag for four small countries costs ~128 OpenFIGI lookups once.
-- Those that genuinely have no US line are re-marked on the next pass and nothing is worse off;
-- the handful that DO have one — an ADR listed after the mark was set — gain it. That is a fair
-- trade for a one-off, and cheaper than another deploy to remove the statement. It is not a
-- template: do not clear a negative cache because a resolver looked idle for five minutes.

do $$
declare
  cleared bigint;
begin
  if exists (select 1 from market.one_shot where key = '64-clear-marks-for-newly-swept-venues') then
    return;
  end if;

  update market.security s
     set figi_missing_at         = null,
         local_symbol_missing_at = null
   where s.country_iso2 in ('KW', 'QA', 'VN', 'AR')
     and (s.figi_missing_at is not null or s.local_symbol_missing_at is not null);

  get diagnostics cleared = row_count;

  insert into market.one_shot (key, reason) values
    ('64-clear-marks-for-newly-swept-venues',
     format('Re-asked OpenFIGI for %s securities in KW, QA, VN and AR after migration 63 added '
            || 'their venues. NOTE: the original justification was wrong — the marks were not '
            || 'blocking symbol resolution, which the cron completed on its own with the marks '
            || 'still set. Kept as a cheap one-off re-ask, not as a precedent.', cleared));
end $$;

notify pgrst, 'reload schema';
