-- Fill in the display metadata for every country that has an ETF — IDEMPOTENT.
--
-- Adding 27 country ETFs made those countries *have data* without making them presentable: flag,
-- region and tier were populated only for the original 19, so Poland had a price series and no
-- flag, no region and no market tier.
--
-- ALL THREE ARE DERIVED, not authored. 27 hand-written rows would have been 27 chances to disagree
-- with the classification data already sitting in the same schema, and the next country added
-- would need a 28th.

-- ── flag: a pure function of the ISO-2 code ──────────────────────────────────
-- A regional-indicator pair. 'PL' -> U+1F1F5 U+1F1F1. Nothing to look up and nothing to get wrong,
-- so a country added tomorrow gets its flag for free.
update market.countries
   set flag = chr(127397 + ascii(substr(upper(iso2), 1, 1))) || chr(127397 + ascii(substr(upper(iso2), 2, 1)))
 where flag is null and iso2 ~ '^[A-Za-z]{2}$';

-- ── region: from the WORLD BANK lens, deliberately ───────────────────────────
-- MSCI's regions are investment regions, not geography: Poland sits in `em-emea`, which would file
-- it under "Middle East & Africa". The World Bank lens is purely geographic, which is what a globe
-- drill-down means.
update market.countries c
   set region_id = m.region
  from (
    select cm.iso2,
           case g.id
             when 'north-america'            then 'north-america'
             when 'latin-america-caribbean'  then 'latin-america'
             when 'europe-central-asia'      then 'europe'
             when 'middle-east-north-africa' then 'mea'
             when 'sub-saharan-africa'       then 'mea'
             when 'east-asia-pacific'        then 'asia-pacific'
             when 'south-asia'               then 'asia-pacific'
           end as region
    from market.classification_members cm
    join market.classification_groups g
      on g.id = cm.group_id and g.scheme_id = cm.scheme_id and g.lens = cm.lens
    where cm.scheme_id = 'world-bank' and cm.lens = 'region'
  ) m
 where m.iso2 = c.iso2 and m.region is not null and c.region_id is null;

-- ── tier: from MSCI, the scheme the app defaults to ──────────────────────────
update market.countries c
   set market = cm.group_id
  from market.classification_members cm
 where cm.iso2 = c.iso2
   and cm.scheme_id = 'msci' and cm.lens = 'tier'
   and c.market is null
   and cm.group_id in ('developed', 'emerging', 'frontier');

-- ── drillable: having an ETF IS what makes a country openable ────────────────
-- It was a hand-maintained boolean that could disagree with whether any data existed. Now it says
-- exactly what it means: there is a price series behind this country.
update market.countries
   set drillable = (etf_symbol is not null)
 where drillable is distinct from (etf_symbol is not null);

notify pgrst, 'reload schema';
