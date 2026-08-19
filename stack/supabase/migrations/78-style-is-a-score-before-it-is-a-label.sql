-- GROWTH VS VALUE, CALIBRATED AGAINST RUSSELL RATHER THAN INVENTED — AND RANKED WITHIN A PEER
-- GROUP, BECAUSE A GLOBAL RANKING CALLS 89% OF THE WORLD "VALUE".
--
-- Russell's published method is a composite value score: book-to-price 50%, I/B/E/S forecast
-- long-term growth 25%, sales-per-share growth 25%. Names near the boundary are carried PARTIALLY
-- IN BOTH indices, which is why the boundary is a band and not a line.
--
-- We hold B/P and sales growth. We cannot license the I/B/E/S forecast. So rather than assume the
-- composite works, it was FITTED against the index's own membership: IWF (Russell 1000 Growth) and
-- IWD (Value) are tracked funds, giving 916 securities with a known label and a score — 125 growth,
-- 576 value, and 215 in BOTH, which is Russell's partial weighting showing up exactly where the
-- method says it should.
--
-- ── THE COHORT IS THE WHOLE DESIGN (measured 2026-08-18) ──────────────────────────────────────
--
-- A first version ranked book-to-price over the entire universe. It scored well and was useless:
--
--   median universe-wide percentile of a Russell 1000 name  =  0.299
--
-- 70% of the world's equities are cheaper than the median US large cap, so a threshold that splits
-- the Russell 1000 sensibly labels **89% of all securities "value"**. As a filter that is worse
-- than no filter — the chip would return almost everything while reading as a judgement.
--
-- Index providers do not do this: MSCI computes value/growth WITHIN each size segment within each
-- market. Ranking within `(msci_tier, cap_band)` reproduces that, and the diagnostic confirms the
-- peer group is fair — the median Russell name moves to **0.430**, i.e. mid-cohort.
--
-- Cohorts measured against the alternatives. Accuracy is FLAT at ~0.71 across every one of them,
-- because the calibration set is 63% value and accuracy is saturated by that class — it cannot
-- choose a cohort. Growth recall and the fallback rate can:
--
--   cohort                  growth recall   median pct   securities with no usable cohort
--   global                       0.55          0.299       0.0%
--   tier                         0.44          0.291       1.3%
--   cap band                     0.37          0.433       0.0%
--   TIER x CAP BAND  <- chosen   0.70          0.430       1.8%
--   country                      0.47          0.380       1.2%
--   country x cap band           0.71          0.525       9.6%
--
-- `country x cap band` centres best but leaves 9.6% of securities in a cohort too small to rank in.
-- Ranking those against a different distribution makes their percentile incomparable with everyone
-- else's — the same class of error as banding a native, non-USD market cap. Tier x cap band costs
-- 1.8% for nearly the same recall, and those 1.8% get NO STYLE AT ALL rather than a number computed
-- against strangers. 10,678 of 10,877 scoreable equities (98.2%) land in one of 7 cohorts.
--
-- ── WHY THE THRESHOLDS ARE NOT THE MOST ACCURATE ONES ────────────────────────────────────────
--
-- Two candidate objectives, both fitted on the cohort scale:
--
--                              accuracy   swaps   growth  blend  value   blend recall
--   max accuracy  (.15/.20)      0.710     4.5%     15%     5%    80%       0.13
--   match Russell (.10/.29)      0.678     2.5%     10%    19%    71%       0.36
--
-- **The proportion-matched thresholds ship.** An outright swap — growth called value or the reverse
-- — is the only error a user ever sees, and matching Russell's own name proportions (14% growth /
-- 23% blend / 63% value) HALVES it. The accuracy given up is paid entirely at the blend/value
-- boundary, which is precisely the boundary Russell itself refuses to draw as a line. Maximising a
-- metric that is 63% one class would have bought a better number and a worse feature: a 5%-wide
-- blend band against Russell's real 23% asserts confidence we measurably do not have.
--
-- An even earlier attempt scored 0.623 against a 0.629 baseline — literally worse than answering
-- "value" every time — because the composite had the direction inverted. It looked like a plausible
-- model and was noise. The per-feature AUC (0.95 for book-to-price, 0.5 = nothing) is what found it.
--
-- Adding sales growth at Russell's 25% weight scored WORSE than book-to-price alone, so the extra
-- term is not earning its place and is left out. **B/P identifies value well (0.84 recall) and
-- identifies growth poorly (0.48)** — that is not a tuning failure, it is the missing forecast
-- component, and `style_confidence` carries it rather than hiding it.
--
-- ── THE REST OF THE DESIGN ───────────────────────────────────────────────────────────────────
--
-- `value_score` is the primary artifact and the label is derived from it. A percentile is the
-- honest thing we know: it supports "the most value-like quintile in emerging Asia" exactly, and it
-- degrades gracefully where the discrete label does not.
--
-- A VIEW, not a table with a refresh resource: the score is a pure function of
-- `security_fundamentals`, which already has its own backlog and TTL. Materialising it would add a
-- second thing to keep fresh and a second way for the two to disagree.
--
-- The percentile covers EQUITIES WITH A POSITIVE P/B ONLY. A negative book value (liabilities
-- exceeding assets) has no meaningful book-to-price, and ranking it would put the most distressed
-- companies at an extreme of the scale — the classic value trap rendered as a feature.

drop view if exists market.security_style;

create view market.security_style as
with scoreable as (
  select
    f.security_id,
    -- Book-to-price. Inverted from `price_to_book` because Russell's composite is expressed that
    -- way round and because high B/P = value reads correctly.
    1.0 / f.price_to_book as book_to_price,
    cm.group_id           as tier,
    case
      when mc.market_cap_usd >= 10e9 then 'large'
      when mc.market_cap_usd >=  2e9 then 'mid'
      when mc.market_cap_usd >     0 then 'small'
    end                   as cap_band
  from market.security_fundamentals f
  join market.security_current sc on sc.security_id = f.security_id
  join market.security s          on s.security_id = f.security_id
  -- Both cohort keys are REQUIRED. A security whose tier or comparable cap is unknown has no peer
  -- group, and a percentile against a different population is not a weaker answer — it is a
  -- different quantity wearing the same name.
  join market.classification_members cm
    on cm.iso2 = sc.country_iso2 and cm.scheme_id = 'msci' and cm.lens = 'tier'
  join market.security_market_cap_usd mc on mc.security_id = f.security_id
  where s.security_type_code = 'equity'
    and f.price_to_book is not null
    and f.price_to_book > 0
    and mc.market_cap_usd > 0
),
cohorted as (
  select
    security_id,
    book_to_price,
    tier || '/' || cap_band as cohort,
    count(*) over (partition by tier, cap_band) as cohort_size,
    percent_rank() over (partition by tier, cap_band order by book_to_price) as value_score
  from scoreable
),
scored as (
  -- A cohort below the floor cannot produce a meaningful percentile — with 4 members the answer is
  -- 0, 0.33, 0.67, 1 regardless of the companies. Dropped rather than pooled: see the header.
  select * from cohorted where cohort_size >= 30
),
index_label as (
  -- The index's own answer, where it has one. A security in BOTH funds is a boundary name carried
  -- with partial weight in each — Russell's own definition of blend, not a contradiction to resolve.
  select
    h.security_id,
    case
      when count(*) filter (where fi.value = 'IWF') > 0
       and count(*) filter (where fi.value = 'IWD') > 0 then 'blend'
      when count(*) filter (where fi.value = 'IWF') > 0 then 'growth'
      when count(*) filter (where fi.value = 'IWD') > 0 then 'value'
    end as style
  from market.fund_holding_current h
  join market.security_identifier fi
    on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  where fi.value in ('IWF', 'IWD')
  group by h.security_id
)
select
  sc.security_id,
  round(sc.value_score::numeric, 4)   as value_score,
  round(sc.book_to_price::numeric, 4) as book_to_price,
  sc.cohort,
  sc.cohort_size,
  coalesce(il.style,
    -- Fitted to reproduce Russell's own name proportions on the 916-security calibration set,
    -- NOT to maximise accuracy. See the header: this halves outright growth<->value swaps.
    case
      when sc.value_score >= 0.29 then 'value'
      when sc.value_score <= 0.10 then 'growth'
      else 'blend'
    end
  )                                   as style,
  case when il.style is not null then 'index' else 'composite' end as style_source,
  -- HOW MUCH TO TRUST IT, from the measured per-class recall. A caller ranking by style should be
  -- able to tell an index fact from a 0.48-recall guess without reading this file.
  case
    when il.style is not null      then 'high'
    when sc.value_score >= 0.29    then 'moderate'  -- value: 0.84 recall
    else 'low'                                      -- growth 0.48 / blend 0.36
  end                                 as style_confidence
from scored sc
left join index_label il on il.security_id = sc.security_id;

comment on view market.security_style is
  'Growth/value, fitted against Russell 1000 Growth/Value membership (IWF/IWD) rather than invented, and ranked WITHIN a (MSCI tier x cap band) peer group because a global ranking labels 89% of the world "value" — the median Russell name sits at the 0.299 percentile globally and 0.430 within its cohort. Thresholds reproduce Russell''s own proportions rather than maximising accuracy, which halves outright growth<->value swaps to 2.5%. Measured recall: value 0.84, growth 0.48, blend 0.36. value_score (a within-cohort percentile) is the primary artifact; the label is derived; style_confidence carries the measured trust.';

grant select on market.security_style to anon, authenticated, service_role;

notify pgrst, 'reload schema';

-- ── style joins the filter spine ──────────────────────────────────────────────────────────────
--
-- Rebuilt here rather than in migration 77 so the two land in dependency order on a fresh database:
-- 77 creates `security_facets` before `security_style` exists, and this replaces it with the style
-- columns attached. Migration 13's pg_depend block drops it on every re-run, so both definitions
-- are re-applied in order every pass.
-- DROP WHICHEVER FORM EXISTS. `IF EXISTS` does NOT protect against a relkind mismatch: measured
-- 2026-08-19, `drop view if exists` on a materialized view raises `"x" is not a view`, and
-- `drop materialized view if exists` on a plain view raises `"x" is not a materialized view` — so
-- neither ordering of the two statements is safe, and the object survives both. Migration 80 turns
-- this relation into a matview, so on every deploy after the first it arrives here as one.
do $$
declare k "char";
begin
  select c.relkind into k from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_facets';
  if k = 'm' then
    execute 'drop materialized view if exists market.security_facets cascade';
  elsif k is not null then
    execute 'drop view if exists market.security_facets cascade';
  end if;
end $$;

create view market.security_facets as
with country_lens as (
  select
    iso2,
    max(group_id) filter (where scheme_id = 'msci'       and lens = 'tier')   as msci_tier,
    max(group_id) filter (where scheme_id = 'msci'       and lens = 'region') as msci_region,
    max(group_id) filter (where scheme_id = 'ftse'       and lens = 'tier')   as ftse_tier,
    max(group_id) filter (where scheme_id = 'ftse'       and lens = 'region') as ftse_region,
    max(group_id) filter (where scheme_id = 'world-bank' and lens = 'tier')   as income_group,
    max(group_id) filter (where scheme_id = 'world-bank' and lens = 'region') as wb_region
  from market.classification_members
  group by iso2
)
select
  sc.security_id,
  sc.symbol,
  sc.name,
  sc.security_type_code,
  sc.sector_id,
  sc.industry,
  sc.country_iso2,
  sc.country_name,
  c.region_id                     as app_region_id,
  c.market                        as country_market,
  cl.msci_tier,
  cl.msci_region,
  cl.ftse_tier,
  cl.ftse_region,
  cl.income_group,
  cl.wb_region,
  mc.market_cap_usd,
  sc.market_cap                   as market_cap_native,
  case
    when mc.market_cap_usd is null      then null
    when mc.market_cap_usd >= 10e9      then 'large'
    when mc.market_cap_usd >=  2e9      then 'mid'
    when mc.market_cap_usd >      0     then 'small'
  end                             as cap_band,
  cur.currency_code,
  cur.source                      as currency_source,
  s.maturity_date,
  s.coupon_rate,
  s.coupon_kind_code,
  s.in_default,
  sc.is_tradeable,
  -- Style. LEFT joined: a security with no positive book value, no known tier or no comparable cap
  -- has no style, and must stay in the list unfiltered rather than vanish.
  sty.style,
  sty.style_source,
  sty.style_confidence,
  sty.value_score,
  sty.cohort                      as style_cohort
from market.security_current sc
join market.security s          on s.security_id = sc.security_id
left join market.countries c    on c.iso2 = sc.country_iso2
left join country_lens cl       on cl.iso2 = sc.country_iso2
left join market.security_market_cap_usd mc on mc.security_id = sc.security_id
left join market.security_currency cur      on cur.security_id = sc.security_id
left join market.security_style sty         on sty.security_id = sc.security_id;

comment on view market.security_facets is
  'The filter spine: every dimension a list can be filtered by, on one row per security. Region, economy tier and income group were seeded in classification_members for 181-221 countries and joined to nothing until this view. cap_band derives from market_cap_usd (the only comparable figure) and is NULL when no FX rate is known. style carries its own source, cohort and measured confidence.';

grant select on market.security_facets to anon, authenticated, service_role;

notify pgrst, 'reload schema';
