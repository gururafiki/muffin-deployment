-- finviz serves US LISTINGS, so the analyst-action backlog must ask only about companies that have
-- one — and it must keep asking, because analysts re-rate.
--
-- WHY THIS EXISTS. Measured 2026-09-07 against the deployed openbb-api, `equity/estimates/
-- price_target?provider=finviz` returns 400 for every suffixed symbol (`SAP.DE`, `005930.KS`,
-- `BHP.AX`, `7203.T`, `SHEL.L`, `NESN.SW`) AND for every OTC foreign-ordinary line OpenFIGI's US
-- lookup hands back (`ASMLF`, `BUDFF`, `TSMWF`, `SAPGF`). It answers for every genuine US line,
-- including ADRs (`TSM`, `NVO`) and mid-caps (`EXC`, `ESS`). None of that is visible in a count: a
-- rejected symbol just means the run learned nothing while reporting success.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE, which is the whole point — the same discipline
-- `a-us-ticker-is-not-a-us-listing.sql` uses for the EPS backlog:
--
--   * "reject a dotted symbol"        — keeps the OTC line T204FF. WRONG.
--   * "keep only primary US listings" — drops the ADR, whose primary flag sits on the home venue.
--   * "keep anything with a US listing" — what shipped.
--
-- and it additionally pins the CURSOR, which the EPS fixture does not exercise: this backlog is a
-- rolling cursor rather than a drain, so a security read three days ago must be excluded and the
-- same security nine days later must return. A `%_missing_at` negative cache here would be a claim
-- about the future — "no rating this week" says nothing permanent about a company.

\set ON_ERROR_STOP on

begin;

insert into market.exchange (exch_code, country_iso2, suffix)
     values ('US', 'US', ''), ('NA', 'NL', '.AS')
on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code, price_targets_fetched_at) values
  -- 1. An ordinary US company, never read. Must be queued.
  ('00000000-0000-0000-0000-000000204a01', 'T204 Domestic Inc', 'equity', null),
  -- 2. The OTC foreign-ordinary line: bare ticker, foreign venue only. finviz 400s on it.
  ('00000000-0000-0000-0000-000000204a02', 'T204 Foreign NV',   'equity', null),
  -- 3. An ADR primary on its HOME venue and also listed in the US. This row is what separates
  --    "has a US listing" from "is primarily US-listed".
  ('00000000-0000-0000-0000-000000204a03', 'T204 Adr Co',       'equity', null),
  -- 4. US-listed and read THREE DAYS ago — inside the seven-day cursor, so not yet due.
  ('00000000-0000-0000-0000-000000204a04', 'T204 Recent Inc',   'equity', now() - interval '3 days'),
  -- 5. US-listed and read NINE DAYS ago — past the cursor, so due again.
  ('00000000-0000-0000-0000-000000204a05', 'T204 Stale Inc',    'equity', now() - interval '9 days'),
  ('00000000-0000-0000-0000-000000204f01', 'T204 Fund',         'equity', null)
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000204a01', 'ticker', 'T204D'),
  ('00000000-0000-0000-0000-000000204a02', 'ticker', 'T204FF'),
  ('00000000-0000-0000-0000-000000204a03', 'ticker', 'T204A'),
  ('00000000-0000-0000-0000-000000204a04', 'ticker', 'T204R'),
  ('00000000-0000-0000-0000-000000204a05', 'ticker', 'T204S')
on conflict (kind_code, value) do nothing;

insert into market.listing (security_id, exch_code, symbol, is_primary) values
  ('00000000-0000-0000-0000-000000204a01', 'US', 'T204D', true),
  -- Foreign venue only. No US line anywhere.
  ('00000000-0000-0000-0000-000000204a02', 'NA', 'T204F', true),
  ('00000000-0000-0000-0000-000000204a03', 'NA', 'T204A', true),
  ('00000000-0000-0000-0000-000000204a03', 'US', 'T204A', false),
  ('00000000-0000-0000-0000-000000204a04', 'US', 'T204R', true),
  ('00000000-0000-0000-0000-000000204a05', 'US', 'T204S', true)
on conflict (security_id, exch_code) do nothing;

-- Every one is a large holding, so fund weight cannot be what separates them.
insert into market.fund_holding (fund_id, security_id, as_of, weight, source_code) values
  ('00000000-0000-0000-0000-000000204f01', '00000000-0000-0000-0000-000000204a01', date '2026-06-30', 9.0, 'sec-nport'),
  ('00000000-0000-0000-0000-000000204f01', '00000000-0000-0000-0000-000000204a02', date '2026-06-30', 9.0, 'sec-nport'),
  ('00000000-0000-0000-0000-000000204f01', '00000000-0000-0000-0000-000000204a03', date '2026-06-30', 9.0, 'sec-nport'),
  ('00000000-0000-0000-0000-000000204f01', '00000000-0000-0000-0000-000000204a04', date '2026-06-30', 9.0, 'sec-nport'),
  ('00000000-0000-0000-0000-000000204f01', '00000000-0000-0000-0000-000000204a05', date '2026-06-30', 9.0, 'sec-nport')
on conflict (fund_id, security_id, as_of) do nothing;

do $$
declare
  q_domestic boolean; q_foreign boolean; q_adr boolean;
  q_recent   boolean; q_stale   boolean; n integer;
begin
  select exists (select 1 from market.pending_price_targets
                  where security_id = '00000000-0000-0000-0000-000000204a01') into q_domestic;
  select exists (select 1 from market.pending_price_targets
                  where security_id = '00000000-0000-0000-0000-000000204a02') into q_foreign;
  select exists (select 1 from market.pending_price_targets
                  where security_id = '00000000-0000-0000-0000-000000204a03') into q_adr;
  select exists (select 1 from market.pending_price_targets
                  where security_id = '00000000-0000-0000-0000-000000204a04') into q_recent;
  select exists (select 1 from market.pending_price_targets
                  where security_id = '00000000-0000-0000-0000-000000204a05') into q_stale;

  if not q_domestic then
    raise exception 'a US-listed equity is missing from pending_price_targets — the backlog now asks about nothing';
  end if;
  if q_foreign then
    raise exception 'the OTC foreign-ordinary line is queued — finviz answers 400 for it, so every call is a wasted request that reports success';
  end if;
  if not q_adr then
    raise exception 'the ADR is not queued — the rule has tightened to "primarily US-listed", which drops a company finviz answers for perfectly';
  end if;
  if q_recent then
    raise exception 'a security read three days ago is queued — the seven-day cursor is not being applied and the head will be re-asked every run';
  end if;
  if not q_stale then
    raise exception 'a security read nine days ago is NOT queued — the cursor never lets a company come back, which turns a rolling backlog into a one-shot drain';
  end if;

  -- THE KEY MAKES A RE-FETCH IDEMPOTENT. finviz serves a rolling ~20 actions per symbol, so the
  -- same action arrives on every run; keyed on (security, date, firm) it overwrites instead of
  -- duplicating. Without this the table would grow by 20 rows per security per run for ever.
  insert into market.security_price_target
    (security_id, published_date, analyst_company, target_from, target_to, status, rating_change, source_code)
  values
    ('00000000-0000-0000-0000-000000204a01', date '2026-09-01', 'T204 Capital', 300, 303, 'Reiterated', 'Neutral', 'finviz'),
    -- An INITIATED action has no previous target. `target_from` null is a fact, not a gap — and it
    -- is the row that would go null if `target_to` were ever read from `price_target`.
    ('00000000-0000-0000-0000-000000204a01', date '2026-08-17', 'T204 Advisors', null, 400, 'Initiated', 'Buy', 'finviz')
  on conflict (security_id, published_date, analyst_company) do update
    set target_to = excluded.target_to, status = excluded.status;

  insert into market.security_price_target
    (security_id, published_date, analyst_company, target_from, target_to, status, rating_change, source_code)
  values
    ('00000000-0000-0000-0000-000000204a01', date '2026-09-01', 'T204 Capital', 300, 310, 'Reiterated', 'Neutral', 'finviz')
  on conflict (security_id, published_date, analyst_company) do update
    set target_to = excluded.target_to, status = excluded.status;

  select count(*) into n from market.security_price_target
   where security_id = '00000000-0000-0000-0000-000000204a01';
  if n <> 2 then
    raise exception 're-fetching the rolling window produced % rows rather than 2 — the key does not make a re-fetch idempotent', n;
  end if;

  select target_to into n from market.security_price_target
   where security_id = '00000000-0000-0000-0000-000000204a01'
     and published_date = date '2026-09-01' and analyst_company = 'T204 Capital';
  if n <> 310 then
    raise exception 'the re-fetched action still reads % — a restated target must overwrite', n;
  end if;

  raise notice '  ok  analyst actions are fetched by US listing, on a rolling cursor, idempotently';
end $$;

rollback;
