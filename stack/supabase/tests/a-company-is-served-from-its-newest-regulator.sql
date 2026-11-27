-- A COMPANY IS SERVED FROM ITS NEWEST REGULATOR.
--
-- WHY. `security_segment_current` chose the newest period PER AXIS, and an axis string belongs to
-- one regulator, so a company holding splits from two regulators was served both, each at its own
-- newest year. Measured 2026-11-27: Advantest (6857.T) served its FY2014 SEC business split beside
-- its FY2026 EDINET one, and Sinopec Shanghai Petrochemical its FY2022 SEC split beside a FY2015
-- CNINFO one. The user's rule: serve only the regulator whose newest annual period is the
-- company's newest; a tie goes to the higher `data_source.priority`.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE:
--   A  sec-segments FY2014  vs edinet FY2026    newest -> edinet; priority-first -> sec-segments
--   B  sec-segments FY2025  vs edinet FY2025    tie    -> sec-segments (260 > 220);
--                                               alphabetical-first or lowest-priority -> edinet
--   C  sec-segments FY2022  vs cninfo FY2015    newest -> sec-segments; "the home regulator" -> cninfo
--   D  dart only                                the control: untouched
--   E  dart FY2025 vs sec-segments FY2020 ON THE SAME IFRS AXIS, the SEC side carrying a segment's
--      total assets. The old view already served DART's revenue (newest per axis) and then
--      attached SEC's 2020 assets through the lateral; the chosen regulator must bound the lateral
--      too, so E's total assets are NULL.
-- A also carries an SEC cross-tab cell, which `security_segment_detail` must stop serving.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Periodia','ZW',false)
  on conflict (iso2) do nothing;
-- `market.currency` is filled by the ingest at RUNTIME, so none of these exist on a fresh database.
insert into market.currency (code) values ('USD'),('JPY'),('CNY'),('KRW') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000020112701','T2011 Moved Regulator KK','equity','ZW'),
  ('00000000-0000-0000-0000-000020112702','T2011 Same Year KK','equity','ZW'),
  ('00000000-0000-0000-0000-000020112703','T2011 Left Home Co','equity','ZW'),
  ('00000000-0000-0000-0000-000020112704','T2011 Steady Co','equity','ZW'),
  ('00000000-0000-0000-0000-000020112705','T2011 Shared Axis Co','equity','ZW')
on conflict do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code, accession_number, reconciled_to) values
  -- A: an old SEC split (60 + 40 = 100) and a new EDINET one (700 + 300 = 1,000).
  ('00000000-0000-0000-0000-000020112701','us-gaap:StatementBusinessSegmentsAxis','a:OldAMember','revenue','annual',date '2014-03-31',60,'USD',1,'sec-segments','A-SEC-2014',100),
  ('00000000-0000-0000-0000-000020112701','us-gaap:StatementBusinessSegmentsAxis','a:OldBMember','revenue','annual',date '2014-03-31',40,'USD',1,'sec-segments','A-SEC-2014',100),
  ('00000000-0000-0000-0000-000020112701','edinet:報告セグメント','edinet:半導体','revenue','annual',date '2026-03-31',700,'JPY',1,'edinet','A-ED-2026',1000),
  ('00000000-0000-0000-0000-000020112701','edinet:報告セグメント','edinet:システム','revenue','annual',date '2026-03-31',300,'JPY',1,'edinet','A-ED-2026',1000),
  -- B: one year from both (30 + 70 SEC; 55 + 45 EDINET).
  ('00000000-0000-0000-0000-000020112702','srt:ProductOrServiceAxis','b:PMember','revenue','annual',date '2025-03-31',30,'USD',1,'sec-segments','B-SEC-2025',100),
  ('00000000-0000-0000-0000-000020112702','srt:ProductOrServiceAxis','b:QMember','revenue','annual',date '2025-03-31',70,'USD',1,'sec-segments','B-SEC-2025',100),
  ('00000000-0000-0000-0000-000020112702','edinet:報告セグメント','edinet:B甲','revenue','annual',date '2025-03-31',55,'JPY',1,'edinet','B-ED-2025',100),
  ('00000000-0000-0000-0000-000020112702','edinet:報告セグメント','edinet:B乙','revenue','annual',date '2025-03-31',45,'JPY',1,'edinet','B-ED-2025',100),
  -- C: SEC newer than the home regulator.
  ('00000000-0000-0000-0000-000020112703','us-gaap:StatementBusinessSegmentsAxis','c:RMember','revenue','annual',date '2022-12-31',80,'CNY',1,'sec-segments','C-SEC-2022',100),
  ('00000000-0000-0000-0000-000020112703','us-gaap:StatementBusinessSegmentsAxis','c:SMember','revenue','annual',date '2022-12-31',20,'CNY',1,'sec-segments','C-SEC-2022',100),
  ('00000000-0000-0000-0000-000020112703','cninfo:分行业','cninfo:石化','revenue','annual',date '2015-12-31',90,'CNY',1,'cninfo','C-CN-2015',100),
  ('00000000-0000-0000-0000-000020112703','cninfo:分行业','cninfo:其他','revenue','annual',date '2015-12-31',10,'CNY',1,'cninfo','C-CN-2015',100),
  -- D: one regulator only.
  ('00000000-0000-0000-0000-000020112704','ifrs-full:SegmentsAxis','d:XMember','revenue','annual',date '2025-12-31',10,'KRW',1,'dart','D-KR-2025',100),
  ('00000000-0000-0000-0000-000020112704','ifrs-full:SegmentsAxis','d:YMember','revenue','annual',date '2025-12-31',90,'KRW',1,'dart','D-KR-2025',100),
  -- E: DART FY2025 and SEC FY2020 on the same axis and members; only SEC states total assets.
  ('00000000-0000-0000-0000-000020112705','ifrs-full:SegmentsAxis','e:M1Member','revenue','annual',date '2025-12-31',50,'KRW',1,'dart','E-KR-2025',100),
  ('00000000-0000-0000-0000-000020112705','ifrs-full:SegmentsAxis','e:M2Member','revenue','annual',date '2025-12-31',50,'KRW',1,'dart','E-KR-2025',100),
  ('00000000-0000-0000-0000-000020112705','ifrs-full:SegmentsAxis','e:M1Member','revenue','annual',date '2020-12-31',40,'USD',1,'sec-segments','E-SEC-2020',100),
  ('00000000-0000-0000-0000-000020112705','ifrs-full:SegmentsAxis','e:M2Member','revenue','annual',date '2020-12-31',60,'USD',1,'sec-segments','E-SEC-2020',100),
  ('00000000-0000-0000-0000-000020112705','ifrs-full:SegmentsAxis','e:M1Member','total_assets','instant',date '2020-12-31',500,'USD',1,'sec-segments','E-SEC-2020',null)
on conflict do nothing;

-- A's SEC cross-tab cell: inside a:OldAMember.
insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code, accession_number, reconciled_to, parent_axis, parent_member) values
  ('00000000-0000-0000-0000-000020112701','srt:ProductOrServiceAxis','a:OldA1Member','revenue','annual',date '2014-03-31',60,'USD',1,'sec-segments','A-SEC-2014',60,
   'us-gaap:StatementBusinessSegmentsAxis','a:OldAMember')
on conflict do nothing;

do $$
declare
  src   text;
  n     int;
  tot   numeric;
  axes  text;
  ta    numeric;
begin
  -- The precondition the tie case rests on: if these priorities ever swap, B's expectation must too.
  if (select priority from market.data_source where code = 'sec-segments')
     <= (select priority from market.data_source where code = 'edinet') then
    raise exception 'precondition: sec-segments must outrank edinet in data_source.priority';
  end if;

  -- The rule, read where every other reader (the detail view, the reconcile guard) reads it.
  select string_agg(distinct source_code, ',') into src from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112701';
  if src is distinct from 'edinet' then
    raise exception 'A must be served from its NEWEST regulator (edinet FY2026), got % (sec-segments = by priority)', src;
  end if;
  select string_agg(distinct source_code, ',') into src from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112702';
  if src is distinct from 'sec-segments' then
    raise exception 'B''s tie must go to the higher priority (sec-segments), got %', src;
  end if;
  select string_agg(distinct source_code, ',') into src from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112703';
  if src is distinct from 'sec-segments' then
    raise exception 'C''s newest regulator is SEC (FY2022 > FY2015), got %', src;
  end if;

  -- A: EDINET's split only, whole, and nothing of 2014. The count and the total are the floor.
  select count(*), coalesce(sum(revenue), 0), string_agg(distinct axis, ',')
    into n, tot, axes
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112701';
  if n <> 2 or tot <> 1000 or axes <> 'edinet:報告セグメント' then
    raise exception 'A must serve EDINET''s FY2026 split alone: got % rows summing % on axes % (4 rows / 1,100 / two axes = both regulators)', n, tot, axes;
  end if;
  select count(*) into n from market.security_segment_detail
   where security_id = '00000000-0000-0000-0000-000020112701';
  if n <> 0 then
    raise exception 'A''s SEC cross-tab cell must not be served once A is served from EDINET: got % rows', n;
  end if;

  -- B: SEC's split only.
  select count(*), coalesce(sum(revenue), 0), string_agg(distinct axis, ',')
    into n, tot, axes
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112702';
  if n <> 2 or tot <> 100 or axes <> 'srt:ProductOrServiceAxis' then
    raise exception 'B must serve the higher-priority regulator alone: got % rows summing % on axes %', n, tot, axes;
  end if;

  -- C: SEC's split only.
  select count(*), coalesce(sum(revenue), 0), string_agg(distinct axis, ',')
    into n, tot, axes
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112703';
  if n <> 2 or tot <> 100 or axes <> 'us-gaap:StatementBusinessSegmentsAxis' then
    raise exception 'C must serve its newest regulator alone: got % rows summing % on axes %', n, tot, axes;
  end if;

  -- D: THE GUARD MUST STAY SILENT ON THE INNOCENT SHAPE.
  select count(*), coalesce(sum(revenue), 0) into n, tot
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112704';
  if n <> 2 or tot <> 100 then
    raise exception 'a one-regulator company must be untouched: got % rows summing %', n, tot;
  end if;

  -- E: DART's revenue, and no SEC asset beside it.
  select count(*), coalesce(sum(revenue), 0) into n, tot
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112705';
  if n <> 2 or tot <> 100 then
    raise exception 'E must serve DART''s FY2025 split: got % rows summing %', n, tot;
  end if;
  select total_assets into ta from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000020112705' and member_code = 'e:M1Member';
  if ta is not null then
    raise exception 'E''s total assets must come from the regulator it is served from: got % (500 = SEC''s FY2020 figure)', ta;
  end if;
end $$;

\echo ok: a company is served from its newest regulator; a tie goes to priority; the others stay stored

rollback;
