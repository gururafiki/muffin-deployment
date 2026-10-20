-- AN NSE WALK THAT LISTS NOTHING IS RECORDED, so the queue reaches the companies behind it.
--
-- MEASURED 2026-10-20. `in-filings` reported `walked: 6, mapped: 0, written: 0, failed: 0,
-- remaining: 295` on every run, every 15 minutes, from at least 2026-10-06, and "A non-empty
-- backlog has been FLAT for a week" fired on `pending_in_history`. The handler records a walk with
-- `update security_filer set history_walked_at = … where source_code = 'nse'`, and creates that
-- row only when NSE lists a filing. When NSE lists nothing, the update matches no row and raises
-- nothing, so the company stays at the head of the weight-ordered queue. The six at the head had
-- no NSE filer row: Embassy Office Parks REIT, Brookfield India Real Estate Trust, Mindspace
-- Business Parks REIT, IndiGrid InvIT and PowerGrid InvIT (trusts, whose results NSE's
-- corporate-filings index does not list as company results), and TD Power Systems (asked as TDPS,
-- a vendor abbreviation). 283 of the 295 queued companies have a filer row and were never reached.
--
-- THE WALK IS RECORDED ON THE SECURITY, NOT BY CREATING A FILER ROW. A `security_filer` row says
-- that the regulator lists the company, and the coverage model counts it as `held`. A row written
-- because we asked under a symbol NSE does not know would claim a registration that does not
-- exist. `nse_history_walked_at` is a CURSOR, a season of 90 days like the filer row's own
-- `history_walked_at`, and deliberately not named `%_missing_at`: a company with nothing indexed
-- this season may file next season.
--
-- IT GOVERNS ONLY WHILE THERE IS NO FILER ROW. Once the NSE id resolves (migration 190's EQUITY_L
-- join, or anything later), the walk under that id is a different question, and the row's own
-- `history_walked_at` decides. Reading the two together (`greatest`, `coalesce`) would hold a
-- company out for 90 days after we learned its right name, and a wrong name is not a missing
-- security.
--
-- One row per security today: BSE listings carry a symbol for 4 of 148, and none of those
-- companies is queued twice (295 rows, 295 securities), so a cursor on the security retires
-- exactly the walk that was made.
--
-- Guard: tests/an-nse-walk-that-lists-nothing-leaves-the-queue.sql, and logic-check's
-- `in-filings` section for the handler.

alter table market.security add column if not exists nse_history_walked_at timestamptz;

comment on column market.security.nse_history_walked_at is
  'When `in-filings` last asked NSE about this company under its LISTING symbol and NSE listed nothing, so there was no `security_filer` row to stamp. A 90-day cursor, read by `pending_in_history` only while the company has no NSE filer row; once one exists, that row''s `history_walked_at` decides.';

create or replace view market.pending_in_history as
SELECT s.security_id,
    COALESCE(sf.filer_id, l.symbol) AS symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.listing l ON l.security_id = s.security_id
     JOIN market.exchange e ON e.exch_code = l.exch_code
     LEFT JOIN market.security_filer sf ON sf.security_id = s.security_id AND sf.source_code = 'nse'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND s.country_iso2 = 'IN'::text AND e.country_iso2 = 'IN'::text AND l.symbol IS NOT NULL
    AND CASE
          WHEN sf.security_id IS NOT NULL
            THEN (sf.history_walked_at IS NULL OR sf.history_walked_at < (now() - '90 days'::interval))
          ELSE (s.nse_history_walked_at IS NULL OR s.nse_history_walked_at < (now() - '90 days'::interval))
        END
  GROUP BY s.security_id, sf.filer_id, l.symbol
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, (COALESCE(sf.filer_id, l.symbol));
