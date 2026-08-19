-- Style: ranked WITHIN a peer group, deferring to the index that defines it, and absent rather than
-- guessed when there is no peer group to rank against.
--
-- WHY THIS IS A TEST. The first version of `security_style` ranked book-to-price globally. It
-- scored well on accuracy and was useless: the median Russell 1000 name sits at the 0.299 percentile
-- of the world universe, because 70% of global equities are cheaper than the median US large cap.
-- A threshold that splits the Russell 1000 sensibly therefore labelled **89% of all securities
-- "value"** — a filter chip that returns almost everything while reading as a judgement.
--
-- Nothing would have raised. Every row had a plausible label, the confusion matrix in the migration
-- header looked respectable, and it was measured on a DIFFERENT scale than the view computes.
--
-- Four properties are pinned, each of which would otherwise fail silently:
--
--   1. the percentile is computed WITHIN (tier x cap band), not globally
--   2. index membership outranks the composite, and `style_source` says which answered
--   3. a security with no usable cohort gets NO style — but is NOT dropped from the universe
--   4. a non-positive book value is excluded, not ranked as the most extreme name on the board

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity'),('bond','Bond') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.currency (code) values ('USD') on conflict do nothing;
insert into market.fx_rate (currency_code, as_of, usd_per_unit, source_code)
  values ('USD', current_date, 1, 'yfinance') on conflict (currency_code, as_of) do nothing;

-- TWO COUNTRIES IN DIFFERENT TIERS. Same cap band, so the ONLY thing separating their cohorts is
-- the tier — which is what makes assertion 1 a test of the partition and not of anything else.
insert into market.countries (iso2, name, flag, market, drillable) values
  ('ZD','Devland','ZD','developed',false),
  ('ZE','Emergland','ZE','emerging',false)
on conflict (iso2) do nothing;
insert into market.classification_schemes (id, name, sort_order) values ('msci','MSCI',1)
  on conflict (id) do nothing;
insert into market.classification_groups (scheme_id, lens, id, name, sort_order) values
  ('msci','tier','developed','Developed',1), ('msci','tier','emerging','Emerging',2)
on conflict (scheme_id, lens, id) do nothing;
insert into market.classification_members (scheme_id, lens, iso2, group_id) values
  ('msci','tier','ZD','developed'), ('msci','tier','ZE','emerging')
on conflict (scheme_id, lens, iso2) do nothing;

-- Build two cohorts of 40, over the 30-member floor. Book-to-price runs 1..40 in DEVELOPED and
-- 101..140 in EMERGING — so every emerging name is cheaper than every developed name, and a GLOBAL
-- ranking would put all 40 developed names in the bottom half.
do $$
declare i integer; sid uuid;
begin
  for i in 1..40 loop
    sid := ('00000000-0000-0000-0000-0000000079' || lpad(i::text, 2, '0'))::uuid;
    insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap)
      values (sid, 'T79 Dev ' || i, 'equity', 'ZD', 'USD', 25e9) on conflict (security_id) do nothing;
    insert into market.security_fundamentals (security_id, price_to_book, as_of, source_code)
      values (sid, 1.0/i, now(), 'yfinance')
      on conflict (security_id) do update set price_to_book = excluded.price_to_book;

    sid := ('00000000-0000-0000-0000-0000000078' || lpad(i::text, 2, '0'))::uuid;
    insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap)
      values (sid, 'T79 Eme ' || i, 'equity', 'ZE', 'USD', 25e9) on conflict (security_id) do nothing;
    insert into market.security_fundamentals (security_id, price_to_book, as_of, source_code)
      values (sid, 1.0/(100+i), now(), 'yfinance')
      on conflict (security_id) do update set price_to_book = excluded.price_to_book;
  end loop;
end $$;

-- 1. THE PERCENTILE IS WITHIN THE COHORT. Each cohort must span the full 0..1 range independently.
--    Under a global ranking the developed cohort would occupy only the bottom half — which is
--    exactly the defect that labelled 89% of the world "value".
do $$
declare dmin numeric; dmax numeric; emin numeric; emax numeric; nd integer; ne integer;
begin
  select min(value_score), max(value_score), count(*) into dmin, dmax, nd
    from market.security_style where cohort = 'developed/large';
  select min(value_score), max(value_score), count(*) into emin, emax, ne
    from market.security_style where cohort = 'emerging/large';

  if nd <> 40 or ne <> 40 then
    raise exception 'expected 40 securities per cohort, got developed=% emerging=%', nd, ne;
  end if;
  if dmin <> 0 or dmax <> 1 then
    raise exception
      'the DEVELOPED cohort spans %..% — a cohort must span the full percentile range on its own, or the score is a global ranking wearing a cohort label (every developed name is more expensive than every emerging one here, so a global rank confines it to the bottom half)', dmin, dmax;
  end if;
  if emin <> 0 or emax <> 1 then
    raise exception 'the EMERGING cohort spans %..% — expected 0..1', emin, emax;
  end if;
end $$;

-- 2. THE SAME BOOK-TO-PRICE SCORES DIFFERENTLY IN DIFFERENT COHORTS. This is the whole point of a
--    peer group: "cheap for an emerging-market large cap" is not "cheap for a developed one".
do $$
declare a numeric; b numeric;
begin
  -- Rank 20 of 40 in each cohort -> the same percentile, from very different book-to-price values.
  select value_score into a from market.security_style
    where security_id = '00000000-0000-0000-0000-000000007920';
  select value_score into b from market.security_style
    where security_id = '00000000-0000-0000-0000-000000007820';
  if a is distinct from b then
    raise exception 'equally-ranked members of two cohorts scored % and % — the partition is not being applied', a, b;
  end if;
end $$;

-- 3. THE INDEX WINS. Take the most EXPENSIVE developed name (book-to-price 1/1, value_score 0, so
--    the composite says "growth") and put it in the Russell VALUE fund. The index must override.
insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000007910', 'T79 Growth Fund', 'equity'),
  ('00000000-0000-0000-0000-000000007911', 'T79 Value Fund',  'equity')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','IWF','00000000-0000-0000-0000-000000007910','yfinance'),
  ('ticker','IWD','00000000-0000-0000-0000-000000007911','yfinance')
on conflict (kind_code, value) do nothing;
insert into market.fund_holding (fund_id, security_id, as_of, weight, source_code) values
  -- security ...7901 has the LOWEST book-to-price in its cohort -> composite says growth.
  ('00000000-0000-0000-0000-000000007911', '00000000-0000-0000-0000-000000007901', current_date, 1.0, 'sec-nport'),
  -- security ...7940 has the HIGHEST -> composite says value; held by BOTH funds -> blend.
  ('00000000-0000-0000-0000-000000007910', '00000000-0000-0000-0000-000000007940', current_date, 1.0, 'sec-nport'),
  ('00000000-0000-0000-0000-000000007911', '00000000-0000-0000-0000-000000007940', current_date, 1.0, 'sec-nport')
on conflict do nothing;

do $$
declare st text; src text; conf text; vs numeric;
begin
  select style, style_source, style_confidence, value_score into st, src, conf, vs
    from market.security_style where security_id = '00000000-0000-0000-0000-000000007901';
  if vs > 0.10 then raise exception 'fixture broken: expected this security at the growth end, score %', vs; end if;
  if st is distinct from 'value' then
    raise exception
      'a Russell 1000 VALUE constituent was labelled % — the composite (0.678 accurate) overrode the index membership that DEFINES the label', coalesce(st,'<null>');
  end if;
  if src is distinct from 'index' then
    raise exception 'style_source is % — a caller cannot tell an index fact from a guess', coalesce(src,'<null>');
  end if;
  if conf is distinct from 'high' then
    raise exception 'an index-labelled security must be high confidence, got %', coalesce(conf,'<null>');
  end if;
end $$;

-- 4. IN BOTH FUNDS IS `blend`. Russell carries boundary names with partial weight in each index;
--    picking one of them would report a boundary as a conviction.
do $$
declare st text;
begin
  select style into st from market.security_style where security_id = '00000000-0000-0000-0000-000000007940';
  if st is distinct from 'blend' then
    raise exception
      'a security held by BOTH IWF and IWD was labelled % — Russell carries boundary names partially in both, which is the definition of blend', coalesce(st,'<null>');
  end if;
end $$;

-- 5. NO INDEX LABEL FALLS BACK TO THE COMPOSITE, and the fitted thresholds are the ones that ship.
do $$
declare st text; src text;
begin
  select style, style_source into st, src
    from market.security_style where security_id = '00000000-0000-0000-0000-000000007939';  -- 2nd highest B/P
  if src is distinct from 'composite' then
    raise exception 'an unlabelled security must be sourced as composite, got %', coalesce(src,'<null>');
  end if;
  if st is distinct from 'value' then
    raise exception 'a near-top book-to-price security should be value, got %', coalesce(st,'<null>');
  end if;
end $$;

-- 5b. THE GROWTH THRESHOLD IS LOAD-BEARING TOO. Nothing above pins it: the only low-book-to-price
--     security so far is index-labelled, so the composite's growth band was never exercised.
--     ...7902 is second-cheapest in its cohort (percentile 1/39 = 0.026) and in no index fund.
do $$
declare st text; src text; vs numeric;
begin
  select style, style_source, value_score into st, src, vs
    from market.security_style where security_id = '00000000-0000-0000-0000-000000007902';
  if src is distinct from 'composite' then
    raise exception 'fixture broken: expected an unlabelled security, got source %', coalesce(src,'<null>');
  end if;
  if st is distinct from 'growth' then
    raise exception
      'a security at the %-percentile of its cohort was labelled % — the fitted growth threshold is 0.10, and moving it silently reclassifies the whole growth band as blend', vs, coalesce(st,'<null>');
  end if;
end $$;

-- 6. NO COHORT MEANS NO STYLE — AND MUST NOT MEAN NO SECURITY. A country with no MSCI tier, or a
--    cohort under the 30-member floor, cannot produce a comparable percentile. Scoring it anyway
--    against a different population is the same class of error as banding a native, non-USD cap.
insert into market.countries (iso2, name, flag, drillable) values ('ZF','Untiered','ZF',false)
  on conflict (iso2) do nothing;
-- THIRTY-FIVE of them, deliberately over the 30-member floor: if the tier join were optional they
-- would clear the floor as a nameless cohort and be scored against each other. In production 142
-- securities have no MSCI tier, so this is the real shape, not a contrived one.
do $$
declare i integer; sid uuid;
begin
  for i in 1..35 loop
    sid := ('00000000-0000-0000-0000-0000000076' || lpad(i::text, 2, '0'))::uuid;
    insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap)
      values (sid, 'T79 No Tier ' || i, 'equity', 'ZF', 'USD', 25e9) on conflict (security_id) do nothing;
    insert into market.security_fundamentals (security_id, price_to_book, as_of, source_code)
      values (sid, 1.0/i, now(), 'yfinance')
      on conflict (security_id) do update set price_to_book = excluded.price_to_book;
  end loop;
end $$;

-- A tiny cohort: developed + SMALL cap, only 3 members, under the floor.
do $$
declare i integer; sid uuid;
begin
  for i in 1..3 loop
    sid := ('00000000-0000-0000-0000-0000000077' || lpad(i::text, 2, '0'))::uuid;
    insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap)
      values (sid, 'T79 Tiny ' || i, 'equity', 'ZD', 'USD', 1e9) on conflict (security_id) do nothing;
    insert into market.security_fundamentals (security_id, price_to_book, as_of, source_code)
      values (sid, 1.0/i, now(), 'yfinance')
      on conflict (security_id) do update set price_to_book = excluded.price_to_book;
  end loop;
end $$;

-- The other half of the cohort key: a tier IS known, but the cap is not comparable. This currency
-- has no FX rate, so `market_cap_usd` is NULL — exactly the case migration 77 refuses to band. It
-- must not be scored either, or it joins a cohort it does not belong to.
insert into market.currency (code) values ('ZFX') on conflict do nothing;
-- THIRTY-FIVE of them, for the same reason as the untiered block: one security would be hidden by
-- the 30-member floor, and the floor is not the guard under test here.
do $$
declare i integer; sid uuid;
begin
  for i in 1..35 loop
    sid := ('00000000-0000-0000-0000-0000000075' || lpad(i::text, 2, '0'))::uuid;
    insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap)
      values (sid, 'T79 No Cap ' || i, 'equity', 'ZD', 'ZFX', 900e9) on conflict (security_id) do nothing;
    insert into market.security_fundamentals (security_id, price_to_book, as_of, source_code)
      values (sid, 1.0/i, now(), 'yfinance')
      on conflict (security_id) do update set price_to_book = excluded.price_to_book;
  end loop;
end $$;
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap) values
  ('00000000-0000-0000-0000-000000007954', 'T79 No Comparable Cap', 'equity', 'ZD', 'ZFX', 900e9)
on conflict (security_id) do nothing;
insert into market.security_fundamentals (security_id, price_to_book, as_of, source_code) values
  ('00000000-0000-0000-0000-000000007954', 0.5, now(), 'yfinance')
on conflict (security_id) do update set price_to_book = excluded.price_to_book;

do $$
declare n integer;
begin
  select count(*) into n from market.security_style s
    join market.security sec on sec.security_id = s.security_id
   where sec.country_iso2 = 'ZF';
  if n <> 0 then
    raise exception
      'a security whose country has no MSCI tier was scored (% of them) — it has no peer group, and 35 of them together are not a peer group either', n;
  end if;

  -- The invariant behind both halves: a scored security ALWAYS names its cohort. A NULL cohort
  -- means the partition keys were missing and the rows were pooled by accident.
  select count(*) into n from market.security_style where cohort is null;
  if n <> 0 then
    raise exception '% securities were scored with a NULL cohort — they were ranked against an unnamed pool', n;
  end if;

  select count(*) into n from market.security_style s
    join market.security sec on sec.security_id = s.security_id
   where sec.currency_code = 'ZFX';
  if n <> 0 then
    raise exception
      'a security with NO COMPARABLE market cap was scored — its cap band is unknown, so it has no cohort, and a percentile against the wrong size segment is a different quantity wearing the same name';
  end if;

  select count(*) into n from market.security_style where cohort = 'developed/small';
  if n <> 0 then
    raise exception
      'a 3-member cohort produced % scored securities — with 3 members the percentile is 0, 0.5, 1 regardless of the companies, which is noise wearing a number', n;
  end if;

  -- …and NONE of them may vanish from the universe. Style is a facet, not a filter: an unscoreable
  -- security still has a country, a sector and a market cap, and must remain filterable by those.
  -- Checked for both reasons a security can be unscoreable — no tier, and no comparable cap.
  select count(*) into n from market.security_facets
   where security_id in ('00000000-0000-0000-0000-000000007601',   -- no MSCI tier
                         '00000000-0000-0000-0000-000000007954');  -- no comparable cap
  if n <> 2 then
    raise exception
      'an unscoreable security was DROPPED from security_facets (% of 2 present) — the style join must be a LEFT join, or every security without a peer group disappears from every list', n;
  end if;
end $$;

-- 7. A NON-POSITIVE BOOK VALUE IS NOT SCORED. 1/-2.0 is the lowest book-to-price possible, so an
--    unfiltered ranking puts the most distressed company at an extreme of the scale.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap) values
  ('00000000-0000-0000-0000-000000007952', 'T79 Negative Book', 'equity', 'ZD', 'USD', 25e9)
on conflict (security_id) do nothing;
insert into market.security_fundamentals (security_id, price_to_book, as_of, source_code) values
  ('00000000-0000-0000-0000-000000007952', -2.0, now(), 'yfinance')
on conflict (security_id) do update set price_to_book = excluded.price_to_book;

do $$
declare n integer;
begin
  select count(*) into n from market.security_style where security_id = '00000000-0000-0000-0000-000000007952';
  if n <> 0 then
    raise exception 'a security with a NEGATIVE book value was scored — it would rank at an extreme of the scale, which is the classic value trap rendered as a feature';
  end if;
end $$;

-- 8. BONDS ARE NOT STYLED. Book-to-price on a bond is meaningless, and bonds are 15,159 of 27,629
--    securities — styling them would make "value" the majority label in the universe by arithmetic.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap) values
  ('00000000-0000-0000-0000-000000007953', 'T79 Bond', 'bond', 'ZD', 'USD', 25e9)
on conflict (security_id) do nothing;
insert into market.security_fundamentals (security_id, price_to_book, as_of, source_code) values
  ('00000000-0000-0000-0000-000000007953', 0.5, now(), 'yfinance')
on conflict (security_id) do update set price_to_book = excluded.price_to_book;

do $$
declare n integer;
begin
  select count(*) into n from market.security_style where security_id = '00000000-0000-0000-0000-000000007953';
  if n <> 0 then raise exception 'a BOND was assigned a growth/value style'; end if;
end $$;

-- 9. STYLE IS REACHABLE FROM THE FILTER SPINE. The whole point is that style is one predicate
--    alongside country and sector, not a second query the caller has to join itself.
do $$
declare st text; src text; coh text;
begin
  select style, style_source, style_cohort into st, src, coh
    from market.security_facets where security_id = '00000000-0000-0000-0000-000000007901';
  if st is distinct from 'value' or src is distinct from 'index' or coh is distinct from 'developed/large' then
    raise exception 'security_facets must carry style, source and cohort (got %/%/%)',
      coalesce(st,'<null>'), coalesce(src,'<null>'), coalesce(coh,'<null>');
  end if;
end $$;

rollback;
