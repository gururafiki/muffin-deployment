-- Resolve provider symbols from ISINs — IDEMPOTENT.
--
-- WHY. `security_identifier.kind_code = 'ticker'` carries OpenFIGI's BLOOMBERG spelling, which the
-- price provider rejects. Measured 2026-08-12: `BRK/B`, `RR/.L` and `WALMEX*.MX` 400 outright,
-- while `6.HK` and `ESSITYB.ST` return "no data" because Hong Kong pads to four digits (`0006.HK`)
-- and Stockholm share classes take a hyphen (`ESSITY-B.ST`). The last two carry no unusual
-- character, so they are invisible to any check that greps for `*` or `/`.
--
-- 2.6% of symbols poisoned 28% of 20-symbol batches on the real ordering, and it concentrates as a
-- backlog drains.

alter table market.security add column if not exists yahoo_symbol_missing_at timestamptz;
comment on column market.security.yahoo_symbol_missing_at is
  'When the ISIN search last failed to return a listing on this security''s home market. Excludes it from pending_yahoo_symbol for 30 days — a security can gain a listing, so this is not permanent.';

create index if not exists security_yahoo_missing_idx on market.security (yahoo_symbol_missing_at);

-- ── the backlog ──────────────────────────────────────────────────────────────
-- Securities the PROVIDER HAS ALREADY REFUSED, which is the honest definition of "needs a better
-- symbol": one of the `*_missing_at` columns is set, meaning some resource asked and got nothing.
-- Deliberately NOT "every security with an ISIN" — that would re-ask Yahoo about ~10,000
-- securities whose symbols already work, for no benefit and against a rate-limited endpoint.
--
-- Ordered by fund weight so the names most visible in the app resolve first, exactly like the other
-- incremental resources.
drop view if exists market.pending_yahoo_symbol;
create view market.pending_yahoo_symbol as
select
  s.security_id,
  isin.value                        as isin,
  s.country_iso2,
  coalesce(ps.symbol, t.value)      as current_symbol,
  coalesce(max(h.weight), 0)        as best_weight
from market.security s
join market.security_identifier isin
  on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and s.country_iso2 is not null
  and (
        s.industry_missing_at     is not null
     or s.profile_missing_at      is not null
     or s.performance_missing_at  is not null
  )
  and (s.yahoo_symbol_missing_at is null or s.yahoo_symbol_missing_at < now() - interval '30 days')
group by s.security_id, isin.value, s.country_iso2, coalesce(ps.symbol, t.value)
order by best_weight desc;

comment on view market.pending_yahoo_symbol is
  'Securities some resource has already failed to fetch, that have an ISIN to resolve from. Heaviest fund weight first.';

grant select on market.pending_yahoo_symbol to service_role;

notify pgrst, 'reload schema';
