-- A COMPANY IS MORE THAN ONE INDUSTRY, AND THE WEIGHT IS THE WHOLE POINT.
--
-- WHY. Amazon classified consumer-discretionary is true and useless — AWS is ~19% of revenue and
-- ~60% of operating income, and that is what moves the valuation. This fixture is built so the
-- candidate rules DISAGREE at every step: revenue share and profit share are deliberately far
-- apart (a derivation that used revenue for both would produce equal weights and pass a weaker
-- test), one segment LOSES money (a rule without the zero clamp emits a negative weight and shares
-- above 1), two members map to ONE node (a rule without the collapse hits
-- `ON CONFLICT DO UPDATE command cannot affect row a second time` and fails the whole statement),
-- and a GEOGRAPHY segment is mapped to a real node (a rule that ignores `kind` would classify
-- Amazon as whatever "Europe" points at).

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZX','Weightland','ZX',false)
  on conflict (iso2) do nothing;
-- Populated by the ingest at runtime, never by a migration, so a fresh database has no USD.
insert into market.currency (code) values ('USD') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000014301','T143 Everything Store','equity','ZX') on conflict do nothing;

-- Two muffin sectors to classify into.
insert into market.taxonomy_node (node_id, taxonomy_id, code, name, level) values
  ('00000000-0000-0000-0000-0000001430a1','muffin','t143-tech','Information technology',1),
  ('00000000-0000-0000-0000-0000001430a2','muffin','t143-retail','Consumer discretionary',1),
  ('00000000-0000-0000-0000-0000001430a3','muffin','t143-europe','Europe (not an industry)',1)
on conflict (taxonomy_id, code) do nothing;

insert into market.segment_concept (code, name, node_id) values
  ('t143-cloud','Cloud infrastructure','00000000-0000-0000-0000-0000001430a1'),
  ('t143-ads','Advertising','00000000-0000-0000-0000-0000001430a1'),
  ('t143-retail','Online retail','00000000-0000-0000-0000-0000001430a2'),
  ('t143-euro','Europe','00000000-0000-0000-0000-0000001430a3')
on conflict (code) do nothing;

insert into market.segment_alias (member_code, concept_code, security_id) values
  ('x:AwsMember','t143-cloud',null),
  -- A SECOND member on the SAME node. Without the collapse the derivation inserts the node twice
  -- in one statement and Postgres rejects the whole thing.
  ('x:AdsMember','t143-ads',null),
  ('x:StoresMember','t143-retail',null),
  ('x:InternationalMember','t143-retail',null),
  ('x:EuropeMember','t143-euro',null)
on conflict do nothing;

-- Revenue: AWS 20, Ads 10, Stores 60, International 10  => 100 total.
--   cloud   = 20%   retail = 70%
-- Operating income: AWS 40, Ads 8, Stores 12, International -20.
--   cloud node  = 48                      retail node = 12 - 20 = -8, clamped to 0
--   denominator = 40+8+12+0 = 60 (the WHOLE split, clamped per member)
--   => cloud = 0.80, retail = 0.00, and 0.20 correctly left UNATTRIBUTED
-- The clamp is LOAD-BEARING here rather than decorative: unclamped the denominator is 48 + (-8) =
-- 40 and cloud's weight becomes 48/40 = **1.2** — a share above 1, which is impossible and which
-- no amount of eyeballing a dashboard would catch. Revenue and profit also disagree sharply
-- (0.30 against 1.00), so a derivation that used revenue for both fails too.
insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code) values
  ('00000000-0000-0000-0000-000000014301','srt:ProductOrServiceAxis','x:AwsMember','revenue','annual',date '2025-12-31',20,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014301','srt:ProductOrServiceAxis','x:AdsMember','revenue','annual',date '2025-12-31',10,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014301','srt:ProductOrServiceAxis','x:StoresMember','revenue','annual',date '2025-12-31',60,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014301','srt:ProductOrServiceAxis','x:InternationalMember','revenue','annual',date '2025-12-31',10,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014301','srt:ProductOrServiceAxis','x:AwsMember','operating_income','annual',date '2025-12-31',40,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014301','srt:ProductOrServiceAxis','x:AdsMember','operating_income','annual',date '2025-12-31',8,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014301','srt:ProductOrServiceAxis','x:StoresMember','operating_income','annual',date '2025-12-31',12,'USD',1,'sec-segments'),
  -- LOSS-MAKING. A weight must not go negative on it.
  ('00000000-0000-0000-0000-000000014301','srt:ProductOrServiceAxis','x:InternationalMember','operating_income','annual',date '2025-12-31',-20,'USD',1,'sec-segments'),
  -- A GEOGRAPHY. Real revenue, mapped to a real node, and must NOT classify the company.
  ('00000000-0000-0000-0000-000000014301','srt:StatementGeographicalAxis','x:EuropeMember','revenue','annual',date '2025-12-31',100,'USD',1,'sec-segments')
on conflict do nothing;

do $$
declare n integer; w numeric; wr numeric; wp numeric;
begin
  perform market.derive_segment_classification();

  -- 1. TWO MEMBERS ON ONE NODE COLLAPSE. Without the group-by the statement fails outright with
  --    SQLSTATE 21000; with a naive fix it emits one of the two and understates the weight.
  select count(*), max(weight) into n, w
    from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301'
     and node_id = '00000000-0000-0000-0000-0000001430a1'
     and source_code = 'segment-revenue';
  if n <> 1 then raise exception 'two members on one node must produce ONE row, got %', n; end if;
  if w <> 0.3000 then
    raise exception 'cloud revenue weight should be 0.30 (AWS 20 + Ads 10 of 100), got %', w;
  end if;

  -- 2. THE SHARES SUM TO 1 — i.e. the denominator is the company, not the member.
  select round(sum(weight), 4) into w from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301' and source_code = 'segment-revenue';
  if w <> 1.0000 then raise exception 'revenue weights must total 1, got %', w; end if;

  -- 3. REVENUE AND PROFIT DISAGREE, which is the entire reason both are stored. Cloud is 30% of
  --    revenue and 80% of profit here (48 of a clamped 60).
  select weight into wr from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301'
     and node_id = '00000000-0000-0000-0000-0000001430a1' and source_code = 'segment-revenue';
  select weight into wp from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301'
     and node_id = '00000000-0000-0000-0000-0000001430a1' and source_code = 'segment-profit';
  if wp <= wr then
    raise exception
      'profit weight (%) must differ from revenue weight (%) — a derivation using revenue for both would pass a weaker test', wp, wr;
  end if;
  if wp <> 0.8000 then raise exception 'cloud profit weight should be 0.80, got %', wp; end if;

  -- 4. A LOSS-MAKING LINE IS CLAMPED TO ZERO, AND THE DENOMINATOR WITH IT. Retail nets -8 here,
  --    so it earns 0.00 of the profit. Clamping only the numerator, or neither, leaves a negative
  --    in the denominator and gives cloud 48/40 = 1.2 — a share above 1.
  select weight into wp from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301'
     and node_id = '00000000-0000-0000-0000-0000001430a2' and source_code = 'segment-profit';
  if wp <> 0.0000 then raise exception 'a loss-making line earns 0.00 of the profit, got %', wp; end if;
  select count(*) into n from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301' and weight < 0;
  if n <> 0 then raise exception 'a weight must never be negative, got % such rows', n; end if;
  select count(*) into n from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301' and weight > 1;
  if n <> 0 then
    raise exception 'a weight must never exceed 1 — an unclamped denominator gives 1.2, got % such rows', n;
  end if;

  -- 5. A GEOGRAPHY IS NOT AN INDUSTRY. Europe has the largest revenue of any member here, so a
  --    derivation ignoring `kind` would make it the company's dominant classification.
  select count(*) into n from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301'
     and node_id = '00000000-0000-0000-0000-0000001430a3';
  if n <> 0 then raise exception 'a geographical segment must never classify a company, got % rows', n; end if;

  raise notice '  ok  weights are per company, clamped, collapsed, and revenue differs from profit';
end $$;

-- ── The two defects that only appeared when the derivation was RUN on real figures ────────────
--
-- Both produced confident, plausible, wrong numbers on Amazon's actual FY2025 data, and neither
-- was visible until the output was read.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000014302','T143 Two Axes','equity','ZX') on conflict do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code) values
  -- The product axis: a 100 split, of which 30 is cloud and 20 is UNMAPPED.
  ('00000000-0000-0000-0000-000000014302','srt:ProductOrServiceAxis','x:AwsMember','revenue','annual',date '2025-12-31',30,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014302','srt:ProductOrServiceAxis','x:StoresMember','revenue','annual',date '2025-12-31',50,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014302','srt:ProductOrServiceAxis','x:NobodyMappedThisMember','revenue','annual',date '2025-12-31',20,'USD',1,'sec-segments'),
  -- The business axis: the SAME 100, cut differently, with cloud disclosed again under its own
  -- member code. Amazon does exactly this — AWS appears on both axes with an identical value.
  ('00000000-0000-0000-0000-000000014302','us-gaap:StatementBusinessSegmentsAxis','x:AwsSegmentMember','revenue','annual',date '2025-12-31',30,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014302','us-gaap:StatementBusinessSegmentsAxis','x:RestMember','revenue','annual',date '2025-12-31',70,'USD',1,'sec-segments')
on conflict do nothing;

insert into market.segment_alias (member_code, concept_code, security_id) values
  ('x:AwsSegmentMember','t143-cloud',null),
  ('x:RestMember','t143-retail',null)
on conflict do nothing;

do $$
declare w numeric; tot numeric;
begin
  perform market.derive_segment_classification();

  -- 7. THE AXES MUST NOT BE UNIONED. Cloud is disclosed on BOTH axes at 30, so summing them gives
  --    60 over a denominator that also double-counts — the first version reported Amazon's
  --    information-technology weight as 0.3066 where the truth is 0.1796, and the shares still
  --    summed to 1.0, which is why it survived a reading. One axis is chosen per metric.
  select weight into w from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014302'
     and node_id = '00000000-0000-0000-0000-0000001430a1' and source_code = 'segment-revenue';
  if w <> 0.3000 then
    raise exception 'cloud must be 0.30 of ONE axis, got % — unioning the axes double-counts it', w;
  end if;

  -- 8. THE DENOMINATOR IS THE WHOLE SPLIT, INCLUDING WHAT NOBODY HAS MAPPED. Dividing by the
  --    mapped total alone invents certainty: on Amazon it reported information technology at
  --    1.0000 of profit — "Amazon is 100% a technology company" — because the two geographic
  --    segments carrying the rest of the profit have no concept. 20 of this fixture's 100 is
  --    unmapped, so the weights must total 0.80 and NOT 1.00.
  select round(sum(weight), 4) into tot from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014302' and source_code = 'segment-revenue';
  if tot <> 0.8000 then
    raise exception
      'weights must total 0.80 — the unmapped fifth is UNATTRIBUTED, not redistributed. Got %', tot;
  end if;

  raise notice '  ok  one axis per metric, and the unmapped share is left unattributed';
end $$;

-- A COMPANY THAT DISCLOSES ONLY A GEOGRAPHIC SPLIT MUST NOT BE CLASSIFIED BY IT.
--
-- The geography guard was DECORATIVE until this fixture existed, and the mutation harness is what
-- found that. Once one axis is chosen per metric by "most mapped members", the product axis in the
-- fixture above always wins — so removing `kind in ('product','business')` changed nothing there
-- and the mutation passed clean. The rules only disagree when the geographic axis is the ONLY one
-- a company has, which is the real case this protects: Apple, Amazon and Cisco all report
-- "business segments" that are regions, and mapping one would classify Apple as whatever "Americas"
-- points at with arithmetic that looks perfectly healthy.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000014303','T143 Regions Only','equity','ZX') on conflict do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code) values
  ('00000000-0000-0000-0000-000000014303','srt:StatementGeographicalAxis','x:EuropeMember','revenue','annual',date '2025-12-31',60,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014303','srt:StatementGeographicalAxis','x:AmericasMember','revenue','annual',date '2025-12-31',40,'USD',1,'sec-segments')
on conflict do nothing;
insert into market.segment_alias (member_code, concept_code, security_id) values
  ('x:AmericasMember','t143-euro',null)
on conflict do nothing;

do $$
declare n integer;
begin
  perform market.derive_segment_classification();
  select count(*) into n from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014303';
  if n <> 0 then
    raise exception
      'a company whose ONLY split is geographic must not be classified by it, got % rows', n;
  end if;
  raise notice '  ok  a purely geographic split classifies nothing';
end $$;

do $$
declare n integer;
begin
  -- 6. THE DERIVATION RETRACTS. An upsert cannot; a segment that stops mapping would otherwise
  --    keep its weight for ever, looking freshly derived — the same defect the performance cache
  --    had when a period the refresh stopped producing outlived the fix.
  delete from market.segment_alias where member_code = 'x:AwsMember';
  delete from market.segment_alias where member_code = 'x:AdsMember';
  perform market.derive_segment_classification();
  select count(*) into n from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000014301'
     and node_id = '00000000-0000-0000-0000-0000001430a1';
  if n <> 0 then
    raise exception 'unmapping a segment must REMOVE its derived weight, still % rows', n;
  end if;
  raise notice '  ok  a weight whose segment stopped mapping is deleted, not left stale';
end $$;

rollback;
