-- An aggregate over `performance` must join on `security_symbol.symbol` — the key it is stored under.
--
-- WHY THIS IS A TEST. `country_sector_performance` resolved constituents as
-- `coalesce(ticker, yfinance_symbol)` — US ticker FIRST — while migration 39 re-keyed
-- `performance.scope_id` to `security_symbol.symbol`, whose precedence is the OPPOSITE: primary
-- listing first. Measured 2026-08-18, **3,596 of 12,350 equities (29%)** had performance under the
-- correct key and none under the stale one, so they vanished from every per-country sector number.
--
-- Nothing raised, because a failed join returns FEWER ROWS rather than an error. It read as "no
-- data for this market" and was "joined on the wrong column" — which is why only ~29 of 45
-- drillable countries showed a sector breakdown.
--
-- The fixture below is exactly that shape: a security whose US ticker and primary listing DIFFER,
-- priced under the primary listing. Under the old join it contributes nothing; under the correct
-- one it contributes.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance', 'yfinance', 100)
  on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker', 'Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, market, etf_symbol, drillable)
  values ('ZZ', 'Testland', 'ZZ', 'emerging', 'TZZ', true)
  on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values ('ZZ', 'ZZ', '.ZZ')
  on conflict (exch_code) do nothing;

-- The fund that represents Testland.
insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000007600', 'T76 Country Fund', 'equity')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'TZZ', '00000000-0000-0000-0000-000000007600', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.tracked_fund (symbol, name, kind, represents_code, enabled) values
  ('TZZ', 'T76 Country Fund', 'country', 'ZZ', true)
on conflict (symbol) do update set represents_code = excluded.represents_code, kind = excluded.kind;

-- THE SECURITY THE OLD JOIN LOST: a US ticker AND a different primary listing.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000007601', 'T76 Dual Keyed', 'equity', 'ZZ')
on conflict (security_id) do nothing;
-- The US/OTC line — what `coalesce(ticker, ...)` would have picked.
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T76USOTC', '00000000-0000-0000-0000-000000007601', 'yfinance')
on conflict (kind_code, value) do nothing;
-- The primary listing — what `security_symbol` resolves to, and what performance is stored under.
insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code) values
  ('00000000-0000-0000-0000-000000007601', 'ZZ', 'T76LOCAL', 'T76LOCAL.ZZ', true, 'yfinance')
on conflict do nothing;

-- Classified, held by the fund, and PRICED under the primary listing only.
insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
select '00000000-0000-0000-0000-000000007601', node_id, 'yfinance', now()
  from market.taxonomy_node where taxonomy_id = 'muffin' and level = 1 and code = 'financials'
on conflict do nothing;

insert into market.fund_holding (fund_id, security_id, as_of, weight, source_code) values
  ('00000000-0000-0000-0000-000000007600', '00000000-0000-0000-0000-000000007601',
   current_date, 5.0, 'sec-nport')
on conflict do nothing;

insert into market.performance (scope, scope_id, period, change_pct, total_return_pct, as_of, stale_after, source)
select 'instrument', sym.symbol, '1y', 12.5, 15.0, now(), now() + interval '1 day', 'yfinance'
  from market.security_symbol sym
 where sym.security_id = '00000000-0000-0000-0000-000000007601'
on conflict (scope, scope_id, period) do update
  set change_pct = excluded.change_pct, total_return_pct = excluded.total_return_pct;

-- 1. THE SECURITY MUST APPEAR. Under the old `coalesce(ticker, ...)` join it contributed nothing,
--    because performance is stored under `T76LOCAL`, not `T76USOTC`.
do $$
declare n integer;
begin
  select count(*) into n from market.country_sector_performance
   where country_iso2 = 'ZZ' and sector_id = 'financials' and period = '1y';
  if n = 0 then
    raise exception
      'a security priced under its PRIMARY listing is missing from the aggregate — the join is using a different symbol precedence than performance.scope_id, which silently dropped 3,596 equities';
  end if;
end $$;

-- 2. Its number must be the one we stored, not a partial average.
do $$
declare c numeric; tr numeric; k integer;
begin
  select change_pct, total_return_pct, constituents into c, tr, k
    from market.country_sector_performance
   where country_iso2 = 'ZZ' and sector_id = 'financials' and period = '1y';
  if c is distinct from 12.5 then
    raise exception 'change_pct is % (expected 12.5)', c;
  end if;
  -- TOTAL RETURN IS SERVED. It existed since migration 72 and this view ignored it entirely.
  if tr is distinct from 15.0 then
    raise exception 'total_return_pct is % (expected 15.0) — the aggregate must serve it, not only change_pct', coalesce(tr::text,'<null>');
  end if;
  if k <> 1 then
    raise exception 'constituents is % (expected 1)', k;
  end if;
end $$;

-- 3. A NULL total return must be EXCLUDED from the mean, never coalesced to change_pct — migration
--    72 is explicit that null means "not computed", not "paid no income".
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000007602', 'T76 No Total Return', 'equity', 'ZZ')
on conflict (security_id) do nothing;
insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code) values
  ('00000000-0000-0000-0000-000000007602', 'ZZ', 'T76NOTR', 'T76NOTR.ZZ', true, 'yfinance')
on conflict do nothing;
insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
select '00000000-0000-0000-0000-000000007602', node_id, 'yfinance', now()
  from market.taxonomy_node where taxonomy_id = 'muffin' and level = 1 and code = 'financials'
on conflict do nothing;
insert into market.fund_holding (fund_id, security_id, as_of, weight, source_code) values
  ('00000000-0000-0000-0000-000000007600', '00000000-0000-0000-0000-000000007602',
   current_date, 5.0, 'sec-nport')
on conflict do nothing;
insert into market.performance (scope, scope_id, period, change_pct, total_return_pct, as_of, stale_after, source)
select 'instrument', sym.symbol, '1y', 100.0, null, now(), now() + interval '1 day', 'yfinance'
  from market.security_symbol sym where sym.security_id = '00000000-0000-0000-0000-000000007602'
on conflict (scope, scope_id, period) do update
  set change_pct = excluded.change_pct, total_return_pct = excluded.total_return_pct;

do $$
declare tr numeric; trk integer; k integer;
begin
  select total_return_pct, total_return_constituents, constituents into tr, trk, k
    from market.country_sector_performance
   where country_iso2 = 'ZZ' and sector_id = 'financials' and period = '1y';
  if k <> 2 then
    raise exception 'both securities should be counted in constituents, got %', k;
  end if;
  if trk <> 1 then
    raise exception 'total_return_constituents should be 1 (only one has a total return), got %', trk;
  end if;
  -- 15.0 is the ONLY non-null total return, so the weighted mean over the non-null subset is 15.0.
  -- If the null had been coalesced to its change_pct (100.0), this would be 57.5.
  if tr is distinct from 15.0 then
    raise exception
      'total_return_pct is % (expected 15.0) — a NULL total return was folded into the mean instead of excluded', tr;
  end if;
end $$;

rollback;
