-- AN AXIS CAN CARRY SEVERAL OVERLAPPING SPLITS, AND SUMMING IT IS WRONG BY AN INTEGER MULTIPLE.
--
-- WHY. Measured on Amazon's Q2-2025 10-Q: the `ProductOrService` axis carries a SEVEN-member split
-- summing to 167,702 **and** a TWO-member split (Product, Service) summing to 167,702, while
-- `StatementBusinessSegments` carries a THREE-member split summing to 167,702 again. So
-- `sum(value)` over one axis DOUBLES the company's revenue and over the table TRIPLES it —
-- silently, in the right units, with no error and a perfectly plausible chart. Nothing downstream
-- can detect it, because every individual number is correct.
--
-- The fixture is built so the candidate rules DISAGREE. A view that ignored `partition_id` returns
-- 9 rows summing to 335,404 where the correct answer is 7 rows summing to 167,702; a view that
-- served the FIRST split found rather than the finest returns 2 rows; and the duplicate-join traps
-- below each return 14. Every one of those is a different, wrong, believable number.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZY','Partitionia','ZY',false)
  on conflict (iso2) do nothing;
-- SEEDED HERE ON PURPOSE: `market.currency` is populated by the ingest at RUNTIME, not by any
-- migration, so on a fresh database USD does not exist and a foreign key would fail for a reason
-- unrelated to what this test is about.
insert into market.currency (code) values ('USD') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000014101','T141 Everything Store','equity','ZY','0001018724')
on conflict do nothing;

insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code) values
  ('00000000-0000-0000-0000-000000014101','0001018724-25-000086','10-Q',date '2025-08-01','sec-segments')
on conflict do nothing;

-- The three splits, exactly as Amazon disclosed them. Partition 1 is the finest that reconciles.
insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code) values
  -- p1: the seven product lines. 61485+40348+30873+15694+12208+5595+1499 = 167,702
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','amzn:OnlineStoresMember','revenue','annual',date '2025-06-30',61485,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','amzn:ThirdPartySellerServicesMember','revenue','annual',date '2025-06-30',40348,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','amzn:AmazonWebServicesMember','revenue','annual',date '2025-06-30',30873,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','amzn:AdvertisingServicesMember','revenue','annual',date '2025-06-30',15694,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','amzn:SubscriptionServicesMember','revenue','annual',date '2025-06-30',12208,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','amzn:PhysicalStoresMember','revenue','annual',date '2025-06-30',5595,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','amzn:OtherServicesMember','revenue','annual',date '2025-06-30',1499,'USD',1,'sec-segments'),
  -- p2: the SAME total, cut two ways. 68246+99456 = 167,702
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','us-gaap:ProductMember','revenue','annual',date '2025-06-30',68246,'USD',2,'sec-segments'),
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','us-gaap:ServiceMember','revenue','annual',date '2025-06-30',99456,'USD',2,'sec-segments'),
  -- Operating income on the business axis. AWS again, with a DIFFERENT value — which is why a
  -- reader that joins across axes on the member name double counts rather than enriching.
  ('00000000-0000-0000-0000-000000014101','us-gaap:StatementBusinessSegmentsAxis','amzn:AmazonWebServicesSegmentMember','operating_income','annual',date '2025-06-30',10160,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000014101','us-gaap:StatementBusinessSegmentsAxis','amzn:AmazonWebServicesSegmentMember','revenue','annual',date '2025-06-30',30873,'USD',1,'sec-segments')
on conflict do nothing;

-- A QUARTER SHARING THE ANNUAL PERIOD END. `period_type` is in the primary key precisely so this
-- cannot replace the annual figure — the failure it prevents is a revenue wrong by 4x with an
-- identical row count.
insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code) values
  ('00000000-0000-0000-0000-000000014101','srt:ProductOrServiceAxis','amzn:AmazonWebServicesMember','revenue','quarter',date '2025-06-30',7718,'USD',1,'sec-segments')
on conflict do nothing;

do $$
declare n integer; v numeric; k integer;
begin
  -- 1. THE VIEW SERVES ONE PARTITION. Ignoring partition_id gives 9 rows / 335,404 here.
  select count(*), coalesce(sum(revenue),0) into n, v
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000014101'
     and axis = 'srt:ProductOrServiceAxis';
  if n <> 7 or v <> 167702 then
    raise exception
      'the product axis must serve the FINEST reconciling split: expected 7 rows summing to 167702, got % rows summing to %. Summing the axis without partition_id gives 335404.', n, v;
  end if;

  -- 2. THE SHARES ARE COMPUTED WITHIN THAT SPLIT, so they total 100 rather than 50.
  select round(sum(revenue_share_pct)) into v
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000014101'
     and axis = 'srt:ProductOrServiceAxis';
  if v <> 100 then
    raise exception 'revenue_share_pct must total 100 within one split, got %', v;
  end if;

  -- 3. A QUARTER DID NOT REPLACE THE ANNUAL FIGURE. Without period_type in the key this is 1.
  select count(*) into n from market.security_segment
   where security_id = '00000000-0000-0000-0000-000000014101'
     and member_code = 'amzn:AmazonWebServicesMember' and metric_code = 'revenue'
     and period_ending = date '2025-06-30';
  if n <> 2 then
    raise exception 'a fiscal-period end must hold BOTH an annual and a quarterly row, got %', n;
  end if;
  -- ...and the ANNUAL one is what the view serves, not the quarter.
  select revenue into v from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000014101'
     and member_code = 'amzn:AmazonWebServicesMember';
  if v <> 30873 then raise exception 'the view must serve the ANNUAL figure, got %', v; end if;

  -- 4. A MARGIN IS PER SEGMENT. AWS: 10160/30873 = 32.91%.
  select operating_margin_pct into v from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000014101'
     and axis = 'us-gaap:StatementBusinessSegmentsAxis';
  if v is null or abs(v - 32.91) > 0.01 then
    raise exception 'segment operating margin should be 32.91, got %', v;
  end if;

  raise notice '  ok  a split is served whole and alone (7 lines, 167702, shares total 100)';
end $$;

-- ── The two joins that can silently double a company's revenue ────────────────────────────────
--
-- Both were latent in the first draft of the view and neither shows up as an error: the numbers
-- stay individually correct and the totals double. `srt:` axes are shared between us-gaap and
-- ifrs-full filers, so the axis collision is real rather than hypothetical, and Part C's Japanese
-- and Korean taxonomies make it likelier.
insert into market.segment_axis (taxonomy, axis, kind, priority) values
  ('ifrs-full','srt:ProductOrServiceAxis','product',80)
on conflict (taxonomy, axis) do nothing;

insert into market.segment_concept (code, name) values ('cloud-infrastructure','Cloud infrastructure')
  on conflict do nothing;
-- The SAME member carries a generic alias and a company-scoped one.
insert into market.segment_alias (member_code, concept_code, security_id) values
  ('amzn:AmazonWebServicesMember','cloud-infrastructure',null),
  ('amzn:AmazonWebServicesMember','cloud-infrastructure','00000000-0000-0000-0000-000000014101')
on conflict do nothing;

do $$
declare n integer;
begin
  select count(*) into n
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000014101'
     and axis = 'srt:ProductOrServiceAxis';
  if n <> 7 then
    raise exception
      'an axis declared under two taxonomies, or a member with two aliases, must not duplicate rows: got % (expected 7). A plain join to segment_axis/segment_alias doubles every figure.', n;
  end if;
  raise notice '  ok  neither a shared axis nor a duplicated alias inflates the split';
end $$;

-- ── The backlog ───────────────────────────────────────────────────────────────────────────────
do $$
declare n integer;
begin
  -- 5. AN UNPARSED FILING IS OFFERED.
  select count(*) into n from market.pending_segments
   where accession_number = '0001018724-25-000086';
  if n <> 1 then raise exception 'an unparsed 10-Q must be queued, got % rows', n; end if;

  -- 6. PARSING IT REMOVES IT — the backlog is satisfiable rather than a treadmill. A filed
  --    document is immutable, so this needs no 30-day expiry: it is a permanent record that we
  --    looked, which is why the column is `segments_parsed_at` and not `%_missing_at`.
  update market.security_filing
     set segments_parsed_at = now(),
         segments_parser_version = (select version from market.segment_parser)
   where accession_number = '0001018724-25-000086';
  select count(*) into n from market.pending_segments
   where accession_number = '0001018724-25-000086';
  if n <> 0 then raise exception 'a parsed filing must leave the backlog, still queued % times', n; end if;

  -- 7. BUMPING THE PARSER VERSION RE-QUEUES IT. This is the supported way to pick up a newly
  --    added `segment_axis` — an operator edit, no deploy and no hand-written UPDATE. Without it
  --    a widened allowlist would only ever apply to filings nobody had read yet.
  update market.segment_parser set version = version + 1;
  select count(*) into n from market.pending_segments
   where accession_number = '0001018724-25-000086';
  if n <> 1 then
    raise exception 'bumping segment_parser.version must re-queue parsed filings, got % rows', n;
  end if;

  -- 8. AN EVENT FILING IS NEVER OFFERED. A 6-K or 8-K carries no audited segment note, and
  --    fetching one costs a request to learn nothing.
  insert into market.security_filing
    (security_id, accession_number, report_type, filing_date, source_code) values
    ('00000000-0000-0000-0000-000000014101','0001018724-25-000099','8-K',date '2025-08-02','sec-segments')
  on conflict do nothing;
  select count(*) into n from market.pending_segments
   where accession_number = '0001018724-25-000099';
  if n <> 0 then raise exception 'an 8-K must never be queued for segment parsing, got % rows', n; end if;

  raise notice '  ok  pending_segments drains, re-queues on a parser bump, and ignores event filings';
end $$;

-- ── THE VOCABULARY MUST NOT BE EMPTY ──────────────────────────────────────────────────────────
--
-- Migrations 141 and 143 shipped the whole machinery INERT: `segment_concept` and `segment_alias`
-- had no rows, so every `concept_code` was null, `derive_segment_classification()` joined to
-- nothing and produced nothing, and the comparison panel had nothing to draw — while every test
-- passed and every resource reported success. That is migration 56's failure exactly (a column a
-- resource filled correctly, sitting at 0 rows in production because its backlog was drained), and
-- "a resource that is never invoked cannot fail" from the same file.
--
-- Nothing downstream can detect an empty control table, so it is asserted here.
do $$
declare n integer;
begin
  select count(*) into n from market.segment_concept;
  if n < 10 then
    raise exception 'segment_concept has % rows — the shared vocabulary is empty, so no business line can be compared across companies', n;
  end if;

  select count(*) into n from market.segment_alias;
  if n < 20 then
    raise exception 'segment_alias has % rows — no filer''s member codes are mapped, so every concept_code is null', n;
  end if;

  -- A concept with no node cannot WEIGHT a classification. Some are legitimately unmapped, but a
  -- vocabulary where none resolves would make the derivation silently produce nothing.
  select count(*) into n from market.segment_concept where node_id is not null;
  if n < 10 then
    raise exception
      'only % concepts resolve to a taxonomy node — derive_segment_classification() would write nothing. Check that the sector codes in migration 145 match market.taxonomy_node.', n;
  end if;

  -- EVERY ALIAS MUST POINT AT A CONCEPT THAT EXISTS. The foreign key guarantees it, but a typo in
  -- a member code does NOT fail: it simply matches no filing, for ever, silently.
  select count(*) into n from market.segment_alias a
   where a.member_code !~ '^[a-z0-9-]+:[A-Za-z0-9]+Member$';
  if n <> 0 then
    raise exception
      '% alias(es) are not shaped like an XBRL member code (`prefix:NameMember`) — a typo here matches nothing for ever and reports success', n;
  end if;

  raise notice '  ok  the shared vocabulary is seeded and every alias is shaped like a member code';
end $$;

rollback;
