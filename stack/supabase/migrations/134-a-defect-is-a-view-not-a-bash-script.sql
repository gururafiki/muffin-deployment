-- A DEFECT IS A VIEW, NOT A BASH SCRIPT.
--
-- `market-verify.yml` computes ~24 numbers every night and keeps a single pass/fail bit. That is
-- the THIRD instance of "computed and thrown away" in this system, after `refresh_log` overwriting
-- every run outcome and the run reports being echoed into an Actions log. As a trend, a defect
-- creeping from 0 to 3 to 11 is visible long before it trips a threshold; as a bit, it is visible
-- the day it breaks and never before.
--
-- ── ONE DEFINITION, TWO CONSUMERS ─────────────────────────────────────────────────────────────
--
-- The zero-expected invariants become a VIEW. Then:
--
--   * `sample_universe()` snapshots it hourly as `defect.<name>` — caught within an hour, and a
--     trend rather than a bit;
--   * `market-verify` asserts on THE SAME VIEW, read AS ANON over HTTP — so it still exercises the
--     anon key path, RLS, grants, PostgREST's schema cache and Cloudflare, which is the whole
--     reason that job exists and is why it must NOT move into the database.
--
-- They cannot drift, because there is one definition. This schema has already paid for the
-- alternative: the venue map lived in two places, drifted to 54 rows against 38, and silently
-- stopped sweeping sixteen venues.
--
-- ── WHAT STAYS IN market-verify ───────────────────────────────────────────────────────────────
--
-- The floors (already covered densely by `universe_sample`), the anon read-latency probe, and the
-- six Python checks — unit medians, derived-vs-filing, quarter-shape, one-period-one-point,
-- significant holdings, retention. Those are statistical or need `urllib`; neither belongs here.
--
-- ── ONE CHECK GETS STRICTLY BETTER BY MOVING ──────────────────────────────────────────────────
--
-- The duplicate-constituent check was a bash pipeline over a 900-row window of ONE sector, because
-- PostgREST caps a response at `PGRST_DB_MAX_ROWS` and the first version compared 1,052 against a
-- truncated page of 1,000 and reported duplicates that did not exist. In SQL there is no cap and
-- no window: it is exact, across every sector.

drop view if exists market.data_defect;

create view market.data_defect as

-- A PLACEHOLDER MUST NEVER BECOME AN IDENTIFIER. SEC writes `<cusip>000000000</cusip>` to mean
-- "no CUSIP" and 72% of holdings carry it; treating it as a value collapsed Accenture, Seagate,
-- TE Connectivity and NXP into a SINGLE security, with every request returning 200 and the only
-- symptom one fund's weights summing to 97.1%.
select 'placeholder_cusip'::text as defect,
       count(*)::bigint          as n,
       'security_identifier rows with the all-zero CUSIP placeholder'::text as detail
  from market.security_identifier where kind_code = 'cusip' and value = '000000000'
union all
select 'placeholder_isin', count(*),
       'security_identifier rows with the all-zero ISIN placeholder'
  from market.security_identifier where kind_code = 'isin' and value = '000000000000'

-- NO DUPLICATE CONSTITUENTS. `security_taxonomy` is many-to-many over sources on purpose, so a
-- security classified by both a filing and a provider appeared TWICE in the sector list and was
-- counted twice in the donut. The percentages still looked right, because renormalising cancels a
-- uniform double count — which is exactly how it survived review.
union all
select 'duplicate_constituents',
       coalesce(sum(rows_ - distinct_), 0),
       'sector_constituents rows beyond one per security, across ALL sectors'
  from (select sector_id, count(*) as rows_, count(distinct security_id) as distinct_
          from market.sector_constituents group by sector_id) q

-- NO FABRICATED TOTAL LOSS. A provider bar with `close: 0` as the latest point made every period
-- compute exactly -100%: 1,078 rows, 154 securities showing -100% on ALL SEVEN periods including
-- `1d`. A security cannot fall 100% in a day and also 100% over a year. Zero bars are dropped at
-- parse now, so this is unreachable rather than merely unlikely.
union all
select 'returns_at_minus_100', count(*),
       'performance rows at exactly -100% — a zero close became a total loss'
  from market.performance where scope = 'instrument' and change_pct = -100

-- A FROZEN SERIES, PER SYMBOL AND NOT PER ROW. A delisted instrument keeps being served its final
-- bars, so every period reads exactly +0.00% — "the market was flat" rather than "this fund is
-- dead". Counting flat ROWS was the wrong test and cried wolf at 12: across 12,348 equities an
-- exact round-trip is ordinary, because most quotes sit on a coarse tick grid (Tokyo and Shenzhen
-- in whole units, Seoul in won). THE DISCRIMINATOR IS THREE WINDOWS AT ONCE: a frozen series is
-- flat on every window, and coincidence cannot land on three. Measured — 36 symbols had one fresh
-- zero, 2 had two, none had three.
union all
select 'frozen_series', count(*),
       'symbols at exactly 0.00% on 3+ periods of a FRESH refresh'
  from (select scope_id from market.performance
         where scope = 'instrument' and change_pct = 0 and as_of > now() - interval '2 days'
         group by scope_id having count(*) >= 3) q

-- A NEGATIVE CACHE CONTRADICTED BY OUR OWN DATA. `performance_missing_at` says the provider has no
-- series while `security_price` holds bars written this week. THE TWO RESOURCES CALL THE SAME
-- ENDPOINT — `security-prices` and `security-performance` both fetch `equity/price/historical` —
-- which is what makes this a contradiction rather than an inference.
--
-- DO NOT WIDEN THIS to `industry_missing_at` or `statements_missing_at`: those come from different
-- endpoints, where "has prices, has no industry" is an ordinary gap and not a contradiction.
union all
select 'contradicted_negative_cache', count(*),
       'securities marked as having no price series while holding recent bars'
  from market.security s
 where s.performance_missing_at is not null
   and exists (select 1 from market.security_price p
                where p.security_id = s.security_id and p.date > current_date - 7)

-- A COUNTRY SILENTLY DROPPED. Taiwan had 534 securities and zero provider symbols because OpenFIGI
-- returns `exchCode` bare for some venues and labelled for others ("KS" vs "TT (Taiwan Stock
-- Exchange)"), so an exact match resolved Korea and dropped Taiwan with no error anywhere. A
-- country with many securities and NO symbols at all is that signature, and nothing else looks
-- like it. Expressed over every country rather than the seven the shell loop happened to name.
union all
select 'country_with_no_symbols', count(*),
       'countries with 20+ equities and not one provider symbol'
  from (select s.country_iso2
          from market.security s
         where s.security_type_code = 'equity' and s.country_iso2 is not null
         group by s.country_iso2
        having count(*) >= 20
           and not exists (select 1 from market.security_provider_symbol sp
                            join market.security s2 using (security_id)
                           where s2.country_iso2 = s.country_iso2)) q

-- A BACKLOG THAT CANNOT BE SATISFIED. `pending_industry` asked "has a sector, has no industry" and
-- expressed the second half as a left join plus `where … is null`, which filters ROWS rather than
-- SECURITIES — so a security kept qualifying through its own level-1 rows and could never leave.
-- AMZN was classified and returned by the backlog in the same minute, for months.
union all
select 'queued_but_already_done', count(*),
       'securities in pending_industry that already have a level-2 industry'
  from market.pending_industry pi
 where exists (select 1 from market.security_taxonomy st
                join market.taxonomy_node tn on tn.node_id = st.node_id
               where st.security_id = pi.security_id and tn.level = 2)

-- IMPLAUSIBLE RETURNS ARE BOUNDED, NOT BANNED — so this is a GAUGE, not a zero-expected invariant.
-- Of 40 securities returning >= +300%, 34 were real (SNDK +2,692%, MU +580%) and 6 were artifacts
-- of a redenomination or an unadjusted action. A jump means either a new redenomination (Tel Aviv
-- switched ILS to agorot and took two securities to ~+9,000%) or that break detection stopped
-- working. Alert on the TREND, never on the value.
union all
select 'extreme_1y_returns', count(*),
       'GAUGE not an invariant: 1y returns >= +1000%, expected non-zero and stable'
  from market.performance
 where scope = 'instrument' and period = '1y' and change_pct >= 1000;

-- ── Plausible bounds are a CONTROL TABLE ──────────────────────────────────────────────────────
--
-- `market.metric` is already a catalogue. Bounds belong on it, so "a margin above 100%" or "a
-- negative revenue" is a ROW rather than a migration — the same idiom as `required_facet` and
-- `macro_indicator`. Left NULL means unbounded, so adding a bound is opt-in and an unseeded
-- metric is never falsely flagged.
alter table market.metric add column if not exists min_plausible numeric;
alter table market.metric add column if not exists max_plausible numeric;

comment on column market.metric.min_plausible is
  'Lowest value that is not obviously wrong. NULL = unbounded. Read by market.data_defect.';
comment on column market.metric.max_plausible is
  'Highest value that is not obviously wrong. NULL = unbounded. Read by market.data_defect.';

-- Seeded only where a bound is genuinely certain. A margin cannot exceed 1 (they are stored as
-- FRACTIONS here — the fraction/percent confusion has bitten three times, and this is also a
-- tripwire for it: values arriving as percents would breach the bound immediately).
update market.metric set min_plausible = -1, max_plausible = 1
 where code in ('profit_margin', 'operating_margin', 'gross_margin')
   and min_plausible is null and max_plausible is null;

create or replace view market.metric_out_of_range as
select m.code as metric_code, count(*)::bigint as n
  from market.security_metric sm
  join market.metric m on m.code = sm.metric_code
 where (m.min_plausible is not null and sm.value < m.min_plausible)
    or (m.max_plausible is not null and sm.value > m.max_plausible)
 group by m.code;

-- ── Sampling quality ──────────────────────────────────────────────────────────────────────────
--
-- A SEPARATE FUNCTION, not an extension of `sample_universe()`. That one is defined in migration
-- 132; redefining it here would leave two definitions in the tree with the later silently winning,
-- which is how migration 106 rebuilt `symbol_cache_classification` from migration 050 and deleted
-- eight entries added since. One definition, one file.
create or replace function market.sample_quality()
returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  ts    timestamptz := now();
  taken integer := 0;
begin
  perform set_config('statement_timeout', '30s', true);

  -- The invariants, as trends rather than a nightly bit.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, 'defect.' || defect, n from market.data_defect
  on conflict do nothing;
  get diagnostics taken = row_count;

  insert into market.universe_sample (sampled_at, metric, value)
  select ts, 'out_of_range.' || metric_code, n from market.metric_out_of_range
  on conflict do nothing;

  -- THE UNIT-FLIP TRIPWIRE. p50 and p99 per metric — 149 ms for all 16 codes, measured. The
  -- fraction/percent confusion has hit this schema THREE times: OpenBB returning performance as a
  -- fraction, the shared `pct()` that rendered NVIDIA at a 46% dividend yield, and
  -- `surprise_percent`. Every one was invisible per row and obvious in the aggregate. A p50 that
  -- moves 100x between two samples is a unit change, and this catches the whole CLASS rather than
  -- one metric at a time.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, 'dist.' || metric_code || '.' || stat, v from (
    select metric_code, 'p50' as stat, percentile_cont(0.5) within group (order by value) as v
      from market.security_metric where period_type = 'ttm' group by metric_code
    union all
    select metric_code, 'p99', percentile_cont(0.99) within group (order by value)
      from market.security_metric where period_type = 'ttm' group by metric_code
  ) q where v is not null
  on conflict do nothing;

  -- PROVENANCE. Measured sec-xbrl 2,114,386 / derived 693,306 / yfinance 614,212 / sec 3,896.
  -- A sudden shift means a provider changed behaviour or a resource stopped writing — neither of
  -- which any count of rows can show, because the total barely moves while the mix does.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, 'provenance.' || source_code, count(*) from market.security_metric
   group by source_code
  on conflict do nothing;

  return taken;
end $$;

revoke all on function market.sample_quality() from public;
grant execute on function market.sample_quality() to service_role;

grant select on market.data_defect, market.metric_out_of_range to anon, authenticated, service_role, metrics_ro;

notify pgrst, 'reload schema';
