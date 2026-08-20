-- The dividend backlog must NOT require the priced symbol to be the US ticker.
--
-- WHY THIS IS A TEST. `security_corporate_action` covers 560 of 12,350 equities, and the reason is
-- not the provider — it is `pending_corporate_actions` requiring `security_symbol = the US ticker`
-- so that a Tiingo action and the price series describe one listing. Correct for Tiingo; it is also
-- what caps coverage at 4.5%, with Japan at 4 of 1,368.
--
-- yfinance is asked with the symbol the bars are keyed on, so the constraint is unnecessary. If it
-- ever creeps back into this view the symptom is silent: coverage simply stops growing outside the
-- US while the resource reports ok.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZJ','Testnippon','ZJ',false)
  on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values ('ZJ','ZJ','.ZJ')
  on conflict (exch_code) do nothing;

-- A NON-US SECURITY: its US ticker and its primary (priced) listing DIFFER. This is precisely the
-- shape Tiingo's backlog excludes — 3,827 equities have a differing precedence.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000008801', 'T88 Foreign Payer', 'equity', 'ZJ')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T88USOTC', '00000000-0000-0000-0000-000000008801', 'yfinance')
on conflict (kind_code, value) do nothing;
-- The DISPLAY symbol and the PROVIDER symbol are deliberately DIFFERENT. With them equal, "fetch
-- by the display symbol" and "fetch by the provider symbol" give the same answer and the
-- assertion below cannot fail — which is exactly how it passed a mutation the first time.
insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code) values
  ('00000000-0000-0000-0000-000000008801', 'ZJ', 'T88LOCAL', 'T88DISPLAY', true, 'yfinance')
on conflict do nothing;
insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-000000008801', 'yfinance', 'T88LOCAL.ZJ')
on conflict (security_id, provider_code) do nothing;

-- 1. THE FOREIGN SECURITY IS IN THE DIVIDEND BACKLOG. Tiingo's view excludes it by construction.
do $$
declare n integer; fetch_sym text;
begin
  select count(*) into n from market.pending_dividends
   where security_id = '00000000-0000-0000-0000-000000008801';
  if n <> 1 then
    raise exception
      'a security whose priced symbol differs from its US ticker is NOT in pending_dividends (% rows) — that constraint is what holds Tiingo at 560 of 12,350, with Japan at 4 of 1,368', n;
  end if;

  -- 2. AND IT IS ASKED FOR BY THE PRICED SYMBOL, not the US OTC line. Asking by the wrong one is
  --    how a USD dividend gets recorded against a KRW price series (migration 68 deleted 33 of 45).
  select fetch_symbol into fetch_sym from market.pending_dividends
   where security_id = '00000000-0000-0000-0000-000000008801';
  if fetch_sym is distinct from 'T88LOCAL.ZJ' then
    raise exception
      'pending_dividends would fetch % — it must use the symbol the BARS are keyed on, or the dividend describes a different listing than the series', coalesce(fetch_sym,'<null>');
  end if;
end $$;

-- 3. CONTRAST: the Tiingo backlog correctly EXCLUDES it. Both views are right; they answer
--    different questions, and this asserts the new one is not a copy of the old one.
do $$
declare n integer;
begin
  select count(*) into n from market.pending_corporate_actions
   where security_id = '00000000-0000-0000-0000-000000008801';
  if n <> 0 then
    raise exception 'fixture broken: pending_corporate_actions should exclude a non-US-ticker security, got % rows', n;
  end if;
end $$;

-- 4. THE NEGATIVE CACHE SUPPRESSES, AND EXPIRES. A company that pays nothing must stop being asked
--    — but only for 30 days, because a non-payer can start paying.
update market.security set dividends_missing_at = now()
 where security_id = '00000000-0000-0000-0000-000000008801';
do $$
declare n integer;
begin
  select count(*) into n from market.pending_dividends
   where security_id = '00000000-0000-0000-0000-000000008801';
  if n <> 0 then raise exception 'a freshly marked security is still in the backlog'; end if;
end $$;

update market.security set dividends_missing_at = now() - interval '31 days'
 where security_id = '00000000-0000-0000-0000-000000008801';
do $$
declare n integer;
begin
  select count(*) into n from market.pending_dividends
   where security_id = '00000000-0000-0000-0000-000000008801';
  if n <> 1 then
    raise exception 'an EXPIRED mark must return the security to the backlog — a non-payer can start paying';
  end if;
end $$;

-- 5. THE CACHE IS CLASSIFIED AND CLEARED. A symbol-keyed flag that `clear_symbol_caches` forgets
--    locks the security out for 30 days after its symbol is corrected — the exact defect that kept
--    4,801 of 12,348 equities out of `pending_prices`.
do $$
declare keyed boolean;
begin
  select symbol_keyed into keyed from market.symbol_cache_classification
   where column_name = 'dividends_missing_at';
  if keyed is null then
    raise exception 'dividends_missing_at is not classified — CI fails on any %%_missing_at column nobody decided about';
  end if;
  if not keyed then
    raise exception 'dividends_missing_at must be SYMBOL-KEYED: yfinance is asked by the priced symbol';
  end if;

  update market.security set dividends_missing_at = now()
   where security_id = '00000000-0000-0000-0000-000000008801';
  perform market.clear_symbol_caches('00000000-0000-0000-0000-000000008801');
  if (select dividends_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-000000008801') is not null then
    raise exception
      'clear_symbol_caches did not clear dividends_missing_at — a corrected symbol would leave the security excluded for 30 days';
  end if;
end $$;

rollback;
