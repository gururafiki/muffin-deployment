-- The sector-classification backlog — IDEMPOTENT.
--
-- WHY. Sector membership is derived from the ELEVEN US SECTOR SPDRs, so it covers US large caps
-- and essentially nothing else: `/sector/information-technology?countryId=south-korea` is empty
-- because XLK holds no Korean securities. Measured 2026-08-10, 514 of 9,786 securities have a
-- sector.
--
-- The fix is a provider opinion (yfinance `equity/profile`), which is keyless and already proven
-- in this stack. It is written as a SECOND SOURCE, never over the filing-derived one:
-- `data_source.priority` has sec-nport at 300 and yfinance at 100, and `security_current` picks by
-- priority — so a security XLK holds keeps its filing-sourced sector and everything else gains one.
--
-- Ordered by fund weight so the names a page actually renders are classified first, and bounded by
-- the same slice-per-run shape as `pending_ticker` — 9,786 profile lookups do not fit one worker.

create or replace view market.pending_profile as
select
  s.security_id,
  t.value as symbol,
  s.name,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_taxonomy st
  on st.security_id = s.security_id and st.source_code = 'yfinance'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where st.security_id is null
  and s.security_type_code = 'equity'
group by s.security_id, t.value, s.name
order by best_weight desc;

grant select on market.pending_profile to service_role;

-- Same shape for per-security returns: a ticker but no recent performance row. This is why most
-- constituents render no % change — market.performance scope='instrument' only ever covered the
-- 35 curated symbols.
create or replace view market.pending_performance as
select
  s.security_id,
  t.value as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.performance p
  on p.scope = 'instrument' and p.scope_id = t.value and p.stale_after > now()
left join market.fund_holding_current h
  on h.security_id = s.security_id
where p.scope_id is null
  and s.security_type_code = 'equity'
group by s.security_id, t.value
order by best_weight desc;

grant select on market.pending_performance to service_role;

notify pgrst, 'reload schema';
