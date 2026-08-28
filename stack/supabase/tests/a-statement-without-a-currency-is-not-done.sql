-- A SECURITY WHOSE STATEMENTS CARRY NO CURRENCY IS NOT FINISHED, AND THE OLD BACKLOG SAID IT WAS.
--
-- WHY THIS IS A TEST. `security_statement.currency` is 0 of 104,972 rows. The column has existed
-- since migration 29 and the resource has always read `reported_currency` — yfinance simply never
-- sends it. SEC does, along with 18 annual periods against yfinance's 4.
--
-- The blocker was never the provider. `pending_statements` exited on "has no statements at all",
-- so the 8,559 securities that already hold four currency-less periods were permanently out of the
-- queue: a better provider could be wired up correctly and would still never be asked about them.
-- That failure is SILENT — the resource reports ok, the backlog reports drained, and the currency
-- stays null forever.
--
-- The three assertions are the three ways this can go wrong, and they pull in OPPOSITE directions:
-- too narrow and the population is locked out again, too wide and every run re-fetches yfinance's
-- same four periods for securities SEC cannot answer for at all.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('sec','SEC EDGAR',200) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZK','Teststan','ZK',false)
  on conflict (iso2) do nothing;

-- A: statements exist, WITHOUT a currency, and there is a US ticker to ask SEC with.
--    This is the 8,559. It must be queued.
insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000008901', 'T89 No Currency', 'equity', 'ZK', 8901)
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T89A', '00000000-0000-0000-0000-000000008901', 'yfinance')
on conflict (kind_code, value) do nothing;
-- The PRICED symbol differs from the US ticker on purpose: with them equal, "asks SEC by the US
-- ticker" and "asks SEC by the fetch symbol" are the same string and assertion 4 cannot fail.
insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-000000008901', 'yfinance', 'T89A.ZK')
on conflict (security_id, provider_code) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000008901', 'income', date '2025-09-27', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

-- B: statements exist WITH a currency. Nothing left to want — must NOT be queued, or the backlog
--    never drains and the resource re-fetches the same rows on every run, forever.
insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000008902', 'T89 Has Currency', 'equity', 'ZK', 8902)
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T89B', '00000000-0000-0000-0000-000000008902', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000008902', 'income', date '2025-09-27', 'USD', '{}'::jsonb, 'sec')
on conflict do nothing;

-- C: statements exist without a currency and there is NO US ticker. SEC is addressable by US
--    ticker only, so re-queueing this buys nothing: the run would spend a call on yfinance and
--    write back the same four currency-less periods.
insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000008903', 'T89 No US Line', 'equity', 'ZK', 8903)
on conflict (security_id) do nothing;
insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-000000008903', 'yfinance', 'T89C.ZK')
on conflict (security_id, provider_code) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000008903', 'income', date '2025-09-27', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

-- D: currency-less WITH a US ticker, but SEC has already been asked and had no filings for it.
--    A US OTC line of a company that files nothing. Without an exit of its own this is re-queued
--    every run for ever: SEC answers nothing, yfinance re-writes the same currency-less periods,
--    the view re-admits it. That shape has now cost this pipeline five separate resources.
insert into market.security (security_id, name, security_type_code, country_iso2, cik, statement_currency_missing_at) values
  ('00000000-0000-0000-0000-000000008904', 'T89 Does Not File', 'equity', 'ZK', 8904, now())
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T89D', '00000000-0000-0000-0000-000000008904', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000008904', 'income', date '2025-09-27', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

-- E: the same, but the mark is older than the 30-day expiry. It must come BACK — a company can
--    begin filing, and a negative cache that never expires is a permanent exclusion.
insert into market.security (security_id, name, security_type_code, country_iso2, cik, statement_currency_missing_at) values
  ('00000000-0000-0000-0000-000000008905', 'T89 Filed Later', 'equity', 'ZK', 8905, now() - interval '40 days')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T89E', '00000000-0000-0000-0000-000000008905', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000008905', 'income', date '2025-09-27', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;


do $$
declare n integer; w text; us text; sym text;
begin
  -- 1. THE LOCKED-OUT POPULATION IS IN THE QUEUE.
  select count(*) into n from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008901';
  if n <> 1 then
    raise exception
      'a security with statements but NO reporting currency is not in pending_statements (% rows) — that is the exit condition holding currency at 0 of 104,972, and it fails silently: the resource reports ok and the backlog reports drained', n;
  end if;

  -- 2. AND IT SAYS WHY, so a run can report which half of the backlog it drained rather than
  --    reporting one number that cannot distinguish "new" from "re-fetched".
  select want into w from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008901';
  if w is distinct from 'no_currency' then
    raise exception 'pending_statements.want is % for a security queued to gain a currency', coalesce(w,'<null>');
  end if;

  -- 3. IT CARRIES THE US TICKER, NOT THE FETCH SYMBOL. `SAP` resolves at SEC and `SAP.DE` does
  --    not, so sending the priced symbol asks a question the provider cannot parse and the
  --    fallback silently becomes the only path.
  select us_ticker, symbol into us, sym from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008901';
  if us is distinct from 'T89A' then
    raise exception 'pending_statements.us_ticker is % — SEC is addressable by the US ticker only', coalesce(us,'<null>');
  end if;
  -- ...while `symbol` stays the priced one, because that is what the yfinance fallback wants.
  if sym is distinct from 'T89A.ZK' then
    raise exception 'pending_statements.symbol is % — the yfinance fallback must still be asked with the symbol the bars are keyed on', coalesce(sym,'<null>');
  end if;

  -- 4. A SECURITY THAT ALREADY HAS ITS CURRENCY IS DONE. Without this the view can never empty.
  select count(*) into n from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008902';
  if n <> 0 then
    raise exception
      'a security whose statements already carry a currency is still queued (% rows) — a backlog that cannot empty spends a rate-limited provider budget on work already done', n;
  end if;

  -- 5. NO US TICKER MEANS NOT QUEUED FOR A CURRENCY. Scope a backlog to the population the field
  --    actually serves — migration 56 shipped a column nothing filled by ignoring this.
  select count(*) into n from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008903';
  if n <> 0 then
    raise exception
      'a currency-less security with NO US ticker is queued (% rows) — SEC cannot answer for it, so the run would re-fetch yfinance''s same four currency-less periods', n;
  end if;
  -- 6. A COMPANY SEC HAS NO FILINGS FOR IS OUT OF THE QUEUE. Not because it is finished — its
  --    statements still have no currency — but because we asked and the answer will not change
  --    this month.
  select count(*) into n from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008904';
  if n <> 0 then
    raise exception
      'a security SEC has already been asked about and had nothing for is still queued (% rows) — this is the re-ask-forever shape: yfinance rewrites the same currency-less periods and the view re-admits it, every run, with the resource reporting ok', n;
  end if;

  -- 7. ...AND THE MARK EXPIRES. 30 days, not never — a company can begin filing, and a permanent
  --    exclusion dressed as a cache is how a backlog quietly shrinks to nothing.
  select count(*) into n from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008905';
  if n <> 1 then
    raise exception
      'a 40-day-old statement_currency_missing_at still excludes the security (% rows) — a negative cache that does not expire is a permanent exclusion', n;
  end if;
end $$;

-- ── 8. AND A SECURITY SEC CANNOT BE ASKED ABOUT AT ALL IS NOT QUEUED ──────────────────────────
--
-- THE FIX FOR A FIVE-DAY STALL. `security-statements` returned byte-identical results on five
-- consecutive runs — `written: 240, remaining: 8668` — because this population admitted securities
-- SEC can never answer for. The gate was `us_ticker is not null`, and a US ticker is NOT a CIK:
-- OpenFIGI's US lookup returns a thin OTC foreign-ordinary line for most foreign companies, so
-- D05.SI and 005930.KS looked addressable and were not. Measured: **0 securities without a CIK
-- have ever received a `sec`-sourced statement**, while 2,416 of them sat in this queue starving
-- the 3,328 that SEC can serve.
insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000008950', 'T89 Foreign No CIK', 'equity', 'ZK', null)
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T89NOCIK', '00000000-0000-0000-0000-000000008950', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-000000008950', 'yfinance', 'T89N.ZK')
on conflict (security_id, provider_code) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000008950', 'income', date '2025-09-27', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

do $$
declare n int;
begin
  select count(*) into n from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008950';
  if n <> 0 then
    raise exception
      'a security with statements, no currency and NO CIK is queued (% rows) — SEC is addressable '
      'only by CIK, so this security can never leave the backlog. This is the stall that returned '
      '`written: 240, remaining: 8668` on five consecutive runs.', n;
  end if;

  -- ...and the CIK holder in the same state IS still queued, or the gate has simply emptied the
  -- backlog rather than scoping it.
  select count(*) into n from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000008901';
  if n <> 1 then
    raise exception
      'a security with statements, no currency and a CIK is NOT queued (% rows) — the CIK gate has '
      'disabled the no_currency population instead of scoping it to what SEC can answer', n;
  end if;
  raise notice '  ok  the no_currency queue is scoped to CIK holders, and still contains them';
end $$;

rollback;

\echo 'ok: a statement without a currency is not done, and the queue is scoped to what SEC can answer'
