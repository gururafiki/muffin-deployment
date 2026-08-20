-- SHARE STATISTICS AND ESTIMATES: THE UNITS, THE KEY, AND THE DIRECTION OF THE SCALE.
--
-- WHY THIS IS A TEST. Nothing here can throw. Every defect it guards produces a number that is the
-- right shape and the wrong magnitude — or the right magnitude and the wrong sign of meaning —
-- which is precisely the class this codebase has shipped before: one shared `pct()` rendered
-- NVIDIA at a 46% dividend yield, and a missing currency rendered CNY 1,023,670,000,000 as $1.02T.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.currency (code, name) values ('KRW','Won') on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZS','Statland','ZS',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009701', 'T97 Stats', 'equity', 'ZS')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T97A', '00000000-0000-0000-0000-000000009701', 'yfinance')
on conflict (kind_code, value) do nothing;

do $$
declare n integer; v numeric; c text;
begin
  -- 1. THE BACKLOG HOLDS A SECURITY WITH NO STATISTICS. Paired with 2 below: a backlog that
  --    returns nothing satisfies an exclusion test perfectly, so only both together mean anything.
  select count(*) into n from market.pending_share_stats
   where security_id = '00000000-0000-0000-0000-000000009701';
  if n <> 1 then
    raise exception 'a security with no share statistics is not queued (% rows)', n;
  end if;

  -- The provider's OWN date, deliberately not today: this table tracks the short-interest
  -- reporting cycle, and keying on the fetch date would mint a row per run and call it history.
  insert into market.security_share_stats
    (security_id, as_of, float_shares, outstanding_shares, short_percent_of_float,
     insider_ownership, institution_ownership, source_code)
  values ('00000000-0000-0000-0000-000000009701', date '2026-07-31', 14569223952, 14594180000,
          0.0097, 0.01648, 0.66482, 'yfinance');

  -- 2. AND DROPS IT ONCE FETCHED, or the resource re-reads the same securities for ever.
  select count(*) into n from market.pending_share_stats
   where security_id = '00000000-0000-0000-0000-000000009701';
  if n <> 0 then
    raise exception 'a security fetched moments ago is still queued (% rows) — the backlog cannot drain', n;
  end if;

  -- 3. THE FRACTIONS ARE STORED AS FRACTIONS. If a writer ever "helpfully" multiplies by 100 on
  --    the way in, a reader that also converts renders 66.482% as 6,648% — and one that does not
  --    renders 0.66% for a company two thirds owned by institutions. Both are plausible.
  select institution_ownership into v from market.security_share_stats
   where security_id = '00000000-0000-0000-0000-000000009701';
  if v is null or v > 1.5 then
    raise exception
      'institution_ownership is % — these columns hold the provider''s FRACTION (0.66482 = 66.482%%), and converting on write hides the convention from every reader', v;
  end if;

  -- 4. A PRICE TARGET CARRIES ITS CURRENCY. A Korean target of 190,200 rendered as "$190,200" is
  --    the Alibaba bug in a new column.
  insert into market.security_estimate
    (security_id, as_of, target_consensus, recommendation, recommendation_mean,
     number_of_analysts, currency_code, source_code)
  values ('00000000-0000-0000-0000-000000009701', current_date, 190200, 'buy', 2.11, 40, 'KRW', 'yfinance');

  select currency_code into c from market.security_estimate
   where security_id = '00000000-0000-0000-0000-000000009701';
  if c is distinct from 'KRW' then
    raise exception 'the price target lost its currency (%) — money without a unit gets a dollar sign', coalesce(c,'<null>');
  end if;

  -- 5. THE CURRENCY IS A FOREIGN KEY, so an unknown code fails the STATEMENT and takes the whole
  --    batch with it. The resource learns codes before writing; this asserts the constraint that
  --    makes that necessary, so nobody removes the learn step as redundant.
  begin
    insert into market.security_estimate
      (security_id, as_of, target_consensus, currency_code, source_code)
    values ('00000000-0000-0000-0000-000000009701', current_date - 1, 1, 'ZZZ', 'yfinance');
    raise exception 'an unknown currency code was accepted — the resource''s learn-first step would be dead code';
  exception when foreign_key_violation then null;
  end;

  -- 6. A RE-FETCH OF THE SAME PERIOD UPDATES IT rather than failing. Short interest is restated,
  --    and a resource that errors on its own second run is a resource that runs once.
  insert into market.security_share_stats
    (security_id, as_of, short_percent_of_float, source_code)
  values ('00000000-0000-0000-0000-000000009701', date '2026-07-31', 0.0102, 'yfinance')
  on conflict (security_id, as_of) do update set short_percent_of_float = excluded.short_percent_of_float;

  select short_percent_of_float into v from market.security_share_stats
   where security_id = '00000000-0000-0000-0000-000000009701' and as_of = date '2026-07-31';
  if v is distinct from 0.0102 then
    raise exception 'a restated short interest did not land (%)', v;
  end if;

  -- 7. BOTH NEW CACHES ARE CLASSIFIED. `negative-caches-are-classified.sql` fails CI on an
  --    unclassified `%_missing_at`; this asserts the DIRECTION, which that file cannot: both are
  --    fetched by the priced symbol, so a corrected symbol must clear them.
  select count(*) into n from market.symbol_cache_classification
   where column_name in ('share_stats_missing_at','estimates_missing_at') and symbol_keyed;
  if n <> 2 then
    raise exception 'the new caches are not classified as symbol-keyed (% of 2) — a corrected symbol would leave them set for 30 days', n;
  end if;
end $$;

rollback;

\echo 'ok: fractions stay fractions, targets carry their currency, and the backlog drains'
