-- `untracked_listing` CALLED 9,976 TRACKED COMPANIES UNTRACKED, INCLUDING SAMSUNG ELECTRONICS.
--
-- The view excluded a listing only when a `security_identifier` row of kind `figi` matched its
-- `composite_figi`. That join can never do the job: measured 2026-08-14, **547 of 27,628 securities
-- have a `figi` identifier at all**. The pipeline identifies securities by ISIN, CUSIP and ticker
-- (from N-PORT) and addresses providers by `security_provider_symbol` — a FIGI is recorded only by
-- `security-local-symbols`, for the minority it has resolved that way.
--
-- So the view was answering "listings whose composite FIGI we have not happened to store", which
-- reads exactly like "listings we do not track" and is a different question. Samsung Electronics is
-- tracked as `005930.KS` with ticker `SSNLF`, and BOTH of its directory rows sat in the untracked
-- view. Every Korean name in a sample of the overlap did: 000070.KS, 000080.KS, 000100.KS…
--
-- It surfaced only when search was extended to read the directory (muffin-ui): the new
-- "Listed, not tracked yet" section would have shown thousands of companies the app tracks, prices
-- and can open — a wrong answer that looks like a feature. Nothing else reads this view, which is
-- why a 10,000-row error had gone unnoticed since migration 25.
--
-- MATCHED ON THE WHOLE SYMBOL, both sides, never on a bare ticker. `l.provider_symbol` is the fully
-- qualified address (`005930.KS`, `TDBOF`), and it is compared against the two places a tracked
-- security records one:
--
--   `security_provider_symbol.symbol`   what we ask the price provider for — 6,315 matches
--   `security_identifier` kind ticker   OpenFIGI's US line, e.g. SSNLF — 5,498 matches
--                                       (9,976 by either; they overlap)
--
-- Joining on `l.ticker` instead would be the obvious shortcut and is unsafe: the directory's ticker
-- is the LOCAL one (`005930`), so it would be compared against US tickers and a short local ticker
-- like `A` or `T` would collide with an unrelated company. Comparing full symbol to full symbol has
-- no such failure mode.
--
-- `not exists` rather than left-join-is-null: a listing can match both an identifier and a provider
-- symbol, and a join would fan out before the filter removed it.

-- INDEXED FOR THE PREDICATES ABOVE, because this view is read by ANON and anon has a 3-second
-- statement timeout that `service_role` does not. `fund_sector_weight` was already caught this way:
-- 7.2s for service_role, `57014 canceling statement due to statement timeout` for the app, and it
-- looked healthy from every probe run with the service key. Two `not exists` lookups per row over a
-- 70,000-row directory is exactly the shape that goes quadratic without them.
--
-- Functional indexes because the predicates are `upper(...)` on both sides: a plain btree on
-- `symbol` cannot serve `upper(ps.symbol) = upper(l.provider_symbol)`.
create index if not exists security_provider_symbol_upper_idx
  on market.security_provider_symbol (upper(symbol));
create index if not exists security_identifier_ticker_upper_idx
  on market.security_identifier (upper(value)) where kind_code = 'ticker';

create or replace view market.untracked_listing as
select
  l.figi,
  l.composite_figi,
  l.exch_code,
  l.ticker,
  l.name,
  l.country_iso2,
  l.provider_symbol
from market.exchange_listing l
where l.name is not null
  -- 1. The original rule, kept: it is exact where it applies.
  and not exists (
    select 1 from market.security_identifier si
     where si.kind_code = 'figi' and si.value = l.composite_figi
  )
  -- 2. The address we actually ask the provider for.
  and not exists (
    select 1 from market.security_provider_symbol ps
     where upper(ps.symbol) = upper(l.provider_symbol)
  )
  -- 3. The US line OpenFIGI resolved for the same company.
  and not exists (
    select 1 from market.security_identifier ti
     where ti.kind_code = 'ticker' and upper(ti.value) = upper(l.provider_symbol)
  );

comment on view market.untracked_listing is
  'Exchange listings the universe does not track. Excluded by composite FIGI, by provider symbol and by resolved ticker — the FIGI alone covered 547 of 27,628 securities and called 9,976 tracked companies untracked, Samsung Electronics among them.';

grant select on market.untracked_listing to anon, authenticated, service_role;

notify pgrst, 'reload schema';
