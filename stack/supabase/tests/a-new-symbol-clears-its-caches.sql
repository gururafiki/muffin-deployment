-- A security that gains or changes a provider symbol loses its symbol-keyed negative caches — and
-- only those, and only when the symbol actually changed.
--
-- WHY THIS EXISTS. The rule lived in two edge-function call sites, and Dagster's symbology lane —
-- the third writer — never called it. Measured 2026-09-26: 409 of the 826 securities it had given a
-- yfinance symbol were still excluded from other families' backlogs by marks set under the OLD
-- spelling (dividends 301, industry 148, share_stats 77). Migration 20260926100000 moved the rule
-- onto the table as a trigger, and repaired the 409 once.
--
-- What each fixture makes load-bearing:
--
--   T926 gains a symbol      the trigger fires on INSERT; symbol-keyed marks go, the ISIN-keyed
--                            `figi_missing_at` and `wikidata_missing_at` stay
--   T926 rewritten           an UPDATE that writes the SAME symbol clears nothing; a changed one
--                            clears
--   T926 adopted             the repair clears a mark OLDER than the adoption and keeps one set
--                            AFTER it (asked with the new symbol, so earned)
--   T926 other symbol        a probe hit for a symbol the security does NOT hold is not an
--                            adoption, so the repair leaves its marks alone
--   the repair is ONE-SHOT   or every deploy would re-clear marks earned since

\set ON_ERROR_STOP on

begin;

insert into market.security (security_id, name, security_type_code, country_iso2,
                             dividends_missing_at, industry_missing_at, figi_missing_at,
                             wikidata_missing_at) values
  ('00000000-0000-0000-0000-000000926a01', 'T926 gains a symbol', 'equity', 'GB',
   now() - interval '2 days', now() - interval '2 days', now() - interval '2 days',
   now() - interval '2 days'),
  ('00000000-0000-0000-0000-000000926a02', 'T926 rewritten', 'equity', 'GB', null, null, null, null),
  ('00000000-0000-0000-0000-000000926a03', 'T926 adopted', 'equity', 'GB', null, null, null, null),
  ('00000000-0000-0000-0000-000000926a04', 'T926 other symbol', 'equity', 'GB', null, null, null, null);

-- 1. INSERT fires, and clears only the symbol-keyed columns.
insert into market.security_provider_symbol (security_id, provider_code, symbol)
values ('00000000-0000-0000-0000-000000926a01', 'yfinance', 'T926A.L');

do $$
declare s record;
begin
  select * into s from market.security where security_id = '00000000-0000-0000-0000-000000926a01';
  if s.dividends_missing_at is not null or s.industry_missing_at is not null then
    raise exception 'a new provider symbol left its symbol-keyed marks in place (dividends %, industry %) — '
                    'the security stays out of those backlogs for up to 30 days',
                    s.dividends_missing_at, s.industry_missing_at;
  end if;
  if s.figi_missing_at is null or s.wikidata_missing_at is null then
    raise exception 'a new provider symbol cleared an ISIN-keyed mark — OpenFIGI and Wikidata are asked '
                    'by ISIN, so a symbol says nothing about them and they would be re-asked for an '
                    'answer already held';
  end if;
  raise notice 'ok  a new symbol clears the symbol-keyed marks and keeps the ISIN-keyed ones';
end $$;

-- 2. Rewriting the same symbol clears nothing; changing it clears.
insert into market.security_provider_symbol (security_id, provider_code, symbol)
values ('00000000-0000-0000-0000-000000926a02', 'yfinance', 'T926B.L');
update market.security set dividends_missing_at = now() - interval '1 day'
 where security_id = '00000000-0000-0000-0000-000000926a02';

update market.security_provider_symbol set symbol = 'T926B.L'
 where security_id = '00000000-0000-0000-0000-000000926a02' and provider_code = 'yfinance';

do $$
begin
  if (select dividends_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-000000926a02') is null then
    raise exception 'rewriting the SAME symbol cleared a mark — nothing new was learned, and the '
                    'provider would be re-asked for an absence already proven';
  end if;
  raise notice 'ok  rewriting the same symbol clears nothing';
end $$;

update market.security_provider_symbol set symbol = 'T926C.L'
 where security_id = '00000000-0000-0000-0000-000000926a02' and provider_code = 'yfinance';

do $$
begin
  if (select dividends_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-000000926a02') is not null then
    raise exception 'a CHANGED symbol kept a mark set under the old spelling';
  end if;
  raise notice 'ok  a changed symbol clears the marks';
end $$;

-- 3. The one-shot repair: only marks older than the adoption, only for the symbol actually held.
insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-000000926a03', 'yfinance', 'T926D.L'),
  ('00000000-0000-0000-0000-000000926a04', 'yfinance', 'T926E.L');

insert into market.identifier_probe (security_id, scheme, provider, asked_with, value, outcome,
                                     observed_at) values
  ('00000000-0000-0000-0000-000000926a03', 'symbol', 'openfigi', 'GB00T926D000', 'T926D.L', 'hit',
   now() - interval '1 day'),
  -- A hit for a DIFFERENT symbol from the one held: not an adoption.
  ('00000000-0000-0000-0000-000000926a04', 'symbol', 'openfigi', 'GB00T926E000', 'T926X.L', 'hit',
   now() - interval '1 day');

-- Marks as they stand today, set straight on the table (the trigger fired when the symbols above
-- were inserted, so these are written after it, exactly like production's stale marks).
update market.security set dividends_missing_at   = now() - interval '2 days',   -- older: cleared
                           share_stats_missing_at = now(),                       -- newer: kept
                           figi_missing_at        = now() - interval '2 days'    -- ISIN-keyed: kept
 where security_id = '00000000-0000-0000-0000-000000926a03';
update market.security set dividends_missing_at   = now() - interval '2 days'
 where security_id = '00000000-0000-0000-0000-000000926a04';

delete from market.one_shot where key = 'clear-marks-older-than-the-adopted-symbol-2026-09-26';

\i stack/supabase/migrations/20260926100000_a_new_symbol_clears_its_caches.sql

do $$
declare a record; b record;
begin
  select * into a from market.security where security_id = '00000000-0000-0000-0000-000000926a03';
  select * into b from market.security where security_id = '00000000-0000-0000-0000-000000926a04';
  if a.dividends_missing_at is not null then
    raise exception 'the repair kept a mark set BEFORE the symbol was adopted';
  end if;
  if a.share_stats_missing_at is null then
    raise exception 'the repair cleared a mark set AFTER the adoption — it was asked with the new '
                    'symbol, so the absence is earned';
  end if;
  if a.figi_missing_at is null then
    raise exception 'the repair cleared an ISIN-keyed mark';
  end if;
  if b.dividends_missing_at is null then
    raise exception 'the repair treated a probe hit for a symbol the security does not hold as an '
                    'adoption';
  end if;
  raise notice 'ok  the repair clears only marks older than the symbol actually adopted';
end $$;

-- 4. ONE-SHOT.
update market.security set dividends_missing_at = now() - interval '3 days'
 where security_id = '00000000-0000-0000-0000-000000926a03';

\i stack/supabase/migrations/20260926100000_a_new_symbol_clears_its_caches.sql

do $$
begin
  if (select dividends_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-000000926a03') is null then
    raise exception 'the repair re-ran on a second deploy';
  end if;
  raise notice 'ok  the repair is one-shot';
end $$;

rollback;
