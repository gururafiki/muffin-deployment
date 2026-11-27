-- CHINA'S SEGMENT NOTE IS READ BY RULE (Phase 6c step 6).
--
-- WHY. Banks, insurers and many state firms print none of the mandated main-business tables, so
-- CNINFO read their reports into no rows. Measured 2026-11-27: of the large Chinese companies
-- (over $2 bn) with no split for FY2023 or later, 47 were banks (~$4.5 T), 9 insurers and 2
-- integrated oil companies, and every one states its operating segments in the financial-statement
-- note `分部报告` / `分部信息`, a table with the segments as columns and `合计` last. muffin-ingest's
-- `cn_note` builds that grid from the PDF's text positions and reads it with `segment_note`, the
-- reader EDINET's notes go through, anchored on the note's own total. Gated 2026-11-27 over the 88
-- large companies' FY2025 reports: 25 now place a revenue split, every one reconciling exactly to
-- its own total (14 from the note: ICBC ¥838,270 m, Bank of China ¥663,127 m of segments before
-- eliminations, China Merchants Bank ¥337,532 m, Ping An ¥1,050,506 m, PetroChina's external
-- revenue ¥2,864,469 m beside a gross ¥4,882,272 m; 11 because muffin-ingest#212 raises the PDF
-- gate from 12 MB to 48 MB), and 3 place operating income only.
--
-- A TABLE OF PLACES IS GEOGRAPHY WHATEVER ITS HEADING SAYS. Bank of China, Hua Xia and Shanghai
-- Pudong print geographic operating segments (境内 / 中国香港澳门台湾, 长三角地区 / 西部地区) under
-- the same `分部报告` heading as business ones; read as business, regions would become business
-- lines. A new rule kind, `member`, names the members that imply a kind, and a table whose members
-- are mostly places is not read (there is no cninfo note axis of kind geography).
--
-- WHAT THIS ADDS.
--   - `segment_note_rule.rule` gains `member` (role geography|business|product);
--   - the reader's vocabulary as `market.segment_note_rule` rows of regulator `cninfo`
--     (muffin-ingest `tests/unit/cninfo_note_rules.py` mirrors them; the lane reads these). Until
--     they exist the note stage is off, so the image could roll first;
--   - the axis the note's segments are written to, `cninfo:经营分部` (business);
--   - a one-shot re-queue of the FY2023+ full reports read into no rows: the note stage reads only
--     a report no main-business table was found in, so no report that holds rows is touched. Their
--     bodies were pruned before decision 5, so stage 1 fetches them again. Measured on production
--     2026-11-27: 806 reports of 414 securities, of 7,202 FY2023+ reports read; ~6 GB to fetch.
--     Reports once refused for their size (over 12 MB) are among them and are fetched again.
--
-- Banks are read as revenue from 营业收入: the user's decision of 2026-11-27 is to follow the
-- filing, and China's banks call the line operating revenue.
--
-- Guarded by tests/china-s-segment-note-is-read-by-rule.sql.

alter table market.segment_note_rule drop constraint if exists segment_note_rule_rule;
alter table market.segment_note_rule add constraint segment_note_rule_rule
  check (rule in ('block', 'heading', 'label', 'concept', 'member'));
alter table market.segment_note_rule drop constraint if exists segment_note_rule_role;
alter table market.segment_note_rule add constraint segment_note_rule_role check (
  (rule = 'block' and role in ('consolidated', 'nonconsolidated'))
  or (rule in ('heading', 'member') and role in ('business', 'product', 'geography', 'skip'))
  or rule in ('label', 'concept')
);
comment on table market.segment_note_rule is
  'A segment-note reader''s vocabulary, per regulator. `block`: the text block holding the note '
  '(role consolidated|nonconsolidated). `heading`: the kind of the tables beneath a heading '
  '(business|product|geography|skip). `label`: a row or column label''s role, a structural one '
  '(total|adjustment|subtotal|subset|skip) or a `market.metric` code. `concept`: a metric an '
  'unlabelled line takes from the concept its members sum to. `member`: the kind a member name '
  'implies; a table whose members mostly imply one kind is read as that kind. Within a rule the '
  'highest priority is tried first, and a label takes the first pattern it matches. Patterns are '
  'Python regular expressions over NFKC-normalised text.';

insert into market.segment_note_rule (regulator, rule, pattern, role, priority, note) values
  ('cninfo', 'heading', '主要客户', 'skip', 60, 'major customers'),
  ('cninfo', 'heading', '地区信息|地理信息|地区分部|区域信息|按地区', 'geography', 40,
   'geographic information: not read (no cninfo note axis of that kind)'),
  ('cninfo', 'heading', '经营分部|业务分部|分部报告|分部信息|报告分部|分部分析', 'business', 30, null),
  ('cninfo', 'label',
   '^其中:?(对外交易收入|来自外部客户的收入|外部客户收入|对外营业收入|外部营业收入)$',
   'revenue', 140, 'external revenue under 其中 is still the revenue a split reconciles to'),
  ('cninfo', 'label', '^其中', 'subset', 130, 'an "of which" row'),
  ('cninfo', 'label', '分部间|内部', 'skip', 120, 'intersegment rows'),
  ('cninfo', 'label', '小计$', 'subtotal', 115, null),
  ('cninfo', 'label', '^(合计|总计|合并|集团合计|本集团合计|合并金额)$', 'total', 110, null),
  ('cninfo', 'label', '^(分部间|地区间|业务间)?(抵销|抵消)$|^合并抵(销|消)$|^抵(销|消)及调整$|^调整$',
   'adjustment', 105,
   'a pure eliminations column; 其他业务及合并抵销 and 未分配 are members (SF Holding''s 未分配 '
   'carries external revenue)'),
  ('cninfo', 'label',
   '^(对外交易收入|来自外部客户的收入|外部客户收入|对外营业收入|外部营业收入|营业收入|营业总收入|营业收入合计|营业总收入合计)$',
   'revenue', 100, null),
  ('cninfo', 'label', '^(分部利润|营业利润|分部经营利润|分部营业利润)', 'operating_income', 90, null),
  ('cninfo', 'member', '地区$|大湾区$|^(境内|境外|国内|海外|中国内地|中国大陆|中国境内|中国境外)',
   'geography', 100, 'regions and home/abroad'),
  ('cninfo', 'member', '香港|澳门|台湾|^总行', 'geography', 100,
   'Bank of China''s 中银香港集团; a bank''s head office in a geographic split'),
  ('cninfo', 'member',
   '^(华东|华南|华北|华中|西南|西北|东北|长三角|珠三角|京津冀|环渤海|粤港澳|中东部|亚太|欧洲|美洲|北美|南美|非洲|中东)',
   'geography', 100, null)
on conflict (regulator, rule, pattern) do update
   set role = excluded.role, priority = excluded.priority, note = excluded.note;

insert into market.segment_axis (taxonomy, axis, kind, priority, required_member)
values ('cninfo', 'cninfo:经营分部', 'business', 80, null)
on conflict do nothing;

do $$
declare
  n int;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-requeue-no-rows-for-the-note-2026-11-27') then
    raise notice 'cninfo-requeue-no-rows-for-the-note: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and f.report_type = '年度报告'
     and lower(f.accession_number) like '%.pdf'
     and f.filing_date >= date '2024-01-01'
     and coalesce(f.segments_parser_version, 0) <> 0  -- read, at some version
     and not exists (select 1 from market.security_segment g
                      where g.security_id = f.security_id
                        and g.accession_number = f.accession_number);
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'cninfo-requeue-no-rows-for-the-note-2026-11-27',
    format('re-queued %s FY2023+ CNINFO full-report rows read into no rows, for the segment note', n));
  raise notice 'cninfo-requeue-no-rows-for-the-note: re-queued % rows', n;
end $$;
