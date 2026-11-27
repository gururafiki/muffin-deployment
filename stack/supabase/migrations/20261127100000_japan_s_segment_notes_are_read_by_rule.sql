-- Japan's segment notes are read by rule, and EDINET's own catalogue files a company's annual
-- reports (Phase 6c step 5a, docs/specs/2026-11-26-more-segment-sources.md).
--
-- WHY A RULE TABLE. An EDINET annual report files its segment note as one text block of HTML
-- (Nintendo's FY2026 instance carries no segment axis). muffin-ingest's `facets.segment_note` reads
-- the note's tables against the report's own tagged totals, and needs a vocabulary: which block is
-- the note, which heading names which kind of table, which label is a total, an adjustment or a
-- metric. Measured 2026-11-27 over 40 random FY2026 reports: 36 read a reconciling revenue split,
-- the other 4 are single-segment companies with no table. Every pattern below changed a result on
-- that gate or is mutation-proven in muffin-ingest's tests. `market.segment_note_rule` holds the
-- vocabulary per regulator, so ESEF's (step 7) and China's note (step 6) are rows, not code.
--
-- WHY A DOCUMENT TABLE (decided 2026-11-27, the user). EDINET has no per-company listing: a
-- filing is found only in the list of everything filed on its day. `market.edinet_document` keeps
-- every annual report (120) and amended annual report (130) those lists name, for every filer,
-- and `market.file_edinet_filings()` files `security_filing` rows for the companies mapped to a
-- filer. A company mapped later (a new listing, a code-list change) gets its history from the
-- table at once, with no replay of ~3,650 stored day lists. ~10,000 rows a year.
--
-- WITHDRAWN IS A STATEMENT ABOUT THE DOCUMENT. A day's list marks a withdrawn report
-- (`withdrawalStatus` 1 or 2) and nulls its type, so the lane records `withdrawn`, and the function
-- removes a withdrawn report's filing rows and the segments read from it: a report EDINET no longer
-- publishes must not stay served.
--
-- Nothing here is enabled: `disclosure_source.edinet` stays disabled until the lane is live.
-- Idempotent.

-- ── The rule table ────────────────────────────────────────────────────────────────────────────

create table if not exists market.segment_note_rule (
  regulator text not null references market.disclosure_source (code),
  rule text not null,
  pattern text not null,
  role text not null,
  priority integer not null default 100,
  note text,
  as_of timestamptz not null default now(),
  primary key (regulator, rule, pattern),
  constraint segment_note_rule_rule check (rule in ('block', 'heading', 'label', 'concept')),
  constraint segment_note_rule_role check (
    (rule = 'block' and role in ('consolidated', 'nonconsolidated'))
    or (rule = 'heading' and role in ('business', 'product', 'geography', 'skip'))
    or rule in ('label', 'concept')
  )
);

comment on table market.segment_note_rule is
  'A segment-note reader''s vocabulary, per regulator. `block`: the text block holding the note '
  '(role consolidated|nonconsolidated). `heading`: the kind of the tables beneath a heading '
  '(business|product|geography|skip). `label`: a row or column label''s role, a structural one '
  '(total|adjustment|subtotal|subset|skip) or a `market.metric` code. `concept`: a metric an '
  'unlabelled line takes from the concept its members sum to. Within a rule the highest priority '
  'is tried first, and a label takes the first pattern it matches. Patterns are Python regular '
  'expressions over NFKC-normalised text.';

grant select on market.segment_note_rule to service_role, ingest_rw, anon, authenticated, metrics_ro;
grant insert, update, delete on market.segment_note_rule to service_role;
-- A CONTROL TABLE THE WORKER READS: `market` grants `ingest_rw` DML on every new table by default.
revoke insert, update, delete, truncate on market.segment_note_rule from ingest_rw;
alter table market.segment_note_rule enable row level security;
drop policy if exists segment_note_rule_read on market.segment_note_rule;
create policy segment_note_rule_read on market.segment_note_rule for select using (true);

-- ── EDINET's catalogue ────────────────────────────────────────────────────────────────────────

create table if not exists market.edinet_document (
  doc_id text primary key,
  edinet_code text not null,
  sec_code text,
  doc_type_code text,
  ordinance_code text,
  form_code text,
  period_start date,
  period_end date,
  filed_on date not null,
  withdrawn boolean not null default false,
  xbrl boolean not null default false,
  parent_doc_id text,
  listed_on date not null,
  source_code text not null default 'edinet' references market.data_source (code),
  as_of timestamptz not null default now()
);

create index if not exists edinet_document_edinet_code_idx on market.edinet_document (edinet_code);

comment on table market.edinet_document is
  'Every annual report (doc type 120) and amended annual report (130) EDINET''s daily lists name, '
  'for every filer, as the list states it. `filed_on` is the submission day in Tokyo; `listed_on` '
  'the day whose list named it. `market.file_edinet_filings()` files the annual reports of mapped '
  'companies into `security_filing`. Written by muffin-ingest''s `edinet_document`.';

grant select, insert, update, delete on market.edinet_document to service_role, ingest_rw;
grant select on market.edinet_document to anon, authenticated, metrics_ro;
alter table market.edinet_document enable row level security;
drop policy if exists edinet_document_public_read on market.edinet_document;
create policy edinet_document_public_read on market.edinet_document for select using (true);

-- ── Filing a company's annual reports from the catalogue ──────────────────────────────────────

drop function if exists market.file_edinet_filings(text[]);
create function market.file_edinet_filings(p_edinet_codes text[] default null)
returns table (filed integer, withdrawn_filings integer, withdrawn_segments integer)
language sql
as $$
  with wanted as (
    select f.security_id, d.doc_id, d.filed_on, d.period_end, d.xbrl
      from market.edinet_document d
      join market.security_filer f on f.source_code = 'edinet' and f.filer_id = d.edinet_code
     -- An annual report is ordinance 010, form 030000; its amendment (doc type 130) is form 030001.
     where d.ordinance_code = '010' and d.form_code = '030000'
       and not d.withdrawn
       and (p_edinet_codes is null or d.edinet_code = any (p_edinet_codes))
  ),
  filed as (
    insert into market.security_filing as sf
           (security_id, accession_number, filing_date, report_date, report_type, source_code, is_xbrl)
    select w.security_id, w.doc_id, w.filed_on, w.period_end, '有価証券報告書', 'edinet', w.xbrl
      from wanted w
    on conflict (security_id, accession_number) do update
       set filing_date = excluded.filing_date,
           report_date = excluded.report_date,
           report_type = excluded.report_type,
           is_xbrl = excluded.is_xbrl
     where (sf.filing_date, sf.report_date, sf.report_type, sf.is_xbrl)
           is distinct from (excluded.filing_date, excluded.report_date, excluded.report_type,
                             excluded.is_xbrl)
    returning 1
  ),
  gone as (
    select d.doc_id
      from market.edinet_document d
     where d.withdrawn and (p_edinet_codes is null or d.edinet_code = any (p_edinet_codes))
  ),
  gone_segments as (
    delete from market.security_segment g
     using gone
     where g.source_code = 'edinet' and g.accession_number = gone.doc_id
    returning 1
  ),
  gone_filings as (
    delete from market.security_filing sf
     using gone
     where sf.source_code = 'edinet' and sf.accession_number = gone.doc_id
    returning 1
  )
  select (select count(*) from filed)::integer,
         (select count(*) from gone_filings)::integer,
         (select count(*) from gone_segments)::integer
$$;

comment on function market.file_edinet_filings(text[]) is
  'Files the annual reports `market.edinet_document` holds for every company mapped to an EDINET '
  'filer (`security_filer`, source edinet), or only the filers named; removes a withdrawn report''s '
  'filing rows and segments. Run by the daily list''s stage 2 and by the registry.';

revoke all on function market.file_edinet_filings(text[]) from public;
grant execute on function market.file_edinet_filings(text[]) to service_role, ingest_rw;

-- ── EDINET's control rows ─────────────────────────────────────────────────────────────────────

insert into market.data_source (code, name, priority)
values ('edinet', 'EDINET (Japan) — Financial Services Agency', 220)
on conflict (code) do nothing;

insert into market.filing_form (source_code, form_code, is_annual, carries_segments, kind)
values ('edinet', '有価証券報告書', true, true, 'accounts')
on conflict (source_code, form_code) do nothing;

insert into market.segment_axis (taxonomy, axis, kind, priority)
values ('edinet', 'edinet:報告セグメント', 'business', 90),
       ('edinet', 'edinet:製品及びサービス', 'product', 100),
       ('edinet', 'edinet:地域', 'geography', 50)
on conflict do nothing;

insert into market.segment_parser (regulator, version)
values ('edinet', 1)
on conflict (regulator) do nothing;

update market.disclosure_source
   set note = 'Measured VIABLE 2026-11-27 through the segment note, not axes: an annual report '
              'files the note as a text block of HTML, read against the report''s own tagged '
              'totals (Toyota''s three segments sum to its 50,684,952 百万円). 36 of 40 random '
              'FY2026 reports read a reconciling revenue split; the other 4 have no table. The '
              'list of a day is the only discovery (no per-company listing), kept as '
              '`market.edinet_document`. Enabled once the lane is live.'
 where code = 'edinet';

-- The vocabulary (muffin-ingest `tests/unit/edinet_rules.py` mirrors these rows).
insert into market.segment_note_rule (regulator, rule, pattern, role, priority, note) values
  ('edinet', 'block',
   '^NotesSegmentInformation(Etc)?ConsolidatedFinancialStatements(IFRS|USGAAP)?TextBlock$',
   'consolidated', 20, 'JGAAP (jpcrp_cor) and IFRS (jpigp_cor) consolidated notes'),
  ('edinet', 'block', '^NotesSegmentInformation(Etc)?FinancialStatementsTextBlock$',
   'nonconsolidated', 10, 'a company without subsidiaries: its figures are NonConsolidatedMember'),
  ('edinet', 'heading', '主要な顧客', 'skip', 60, 'major customers'),
  ('edinet', 'heading', '差異|差額', 'skip', 60, 'reconciliation to the statements'),
  ('edinet', 'heading', '減損損失|のれん', 'skip', 60, 'impairment and goodwill tables name the segments'),
  ('edinet', 'heading', '報告セグメント', 'business', 30, null),
  ('edinet', 'heading', '製品及びサービス', 'product', 20, null),
  ('edinet', 'heading', '地域', 'geography', 10, null),
  ('edinet', 'label', '^うち', 'subset', 130, 'an "of which" column or row'),
  ('edinet', 'label', '顧客との契約から生じる収益|^その他の収益|一時点で移転|一定の期間にわたり移転',
   'skip', 125, 'revenue disaggregation rows, never the revenue line'),
  ('edinet', 'label', 'セグメント間', 'skip', 120, 'intersegment sales'),
  ('edinet', 'label', '小計', 'subtotal', 115, null),
  ('edinet', 'label', '^\(?(連結|合計|総計|計)\)?$|計上額$|^報告セグメント計$', 'total', 110, null),
  ('edinet', 'label', '消去|調整|全社', 'adjustment', 105, null),
  ('edinet', 'label',
   '外部顧客(への|に対する)(売上高|営業収益|売上収益)|^(売上高|営業収益|売上収益|外部収益)$',
   'revenue', 100, null),
  ('edinet', 'label', '粗利益', 'skip', 95, 'a bank''s gross operating profit is not revenue'),
  ('edinet', 'label', '^(セグメント利益|営業利益|セグメント利益又は損失|営業損益)',
   'operating_income', 90, null),
  ('edinet', 'label', '^(セグメント資産|資産合計)$', 'total_assets', 85, null),
  ('edinet', 'label', '減価償却費', 'depreciation', 80, null),
  ('edinet', 'label', '有形固定資産及び無形固定資産の増加額|^資本的支出$', 'capital_expenditure', 75,
   'before the bare 有形固定資産'),
  ('edinet', 'label', '有形固定資産|非流動資産', 'long_lived_assets', 70, null),
  ('edinet', 'concept',
   '^(?!.*(Gain|Loss|Proceeds|Cost|Receivable|Payable|Expense|Allowance|Tax|Deferred|Unearned)).*(NetSales|Revenue)',
   'revenue', 10, 'GainOnSalesOfNoncurrentAssetsEI contains "Sales" and is not revenue')
on conflict (regulator, rule, pattern) do update
   set role = excluded.role, priority = excluded.priority, note = excluded.note;

-- Region and country names as Japanese notes write them, as geography members. A company whose
-- reportable segments ARE regions (Makita, Anest Iwata, Chugoku Marine Paints) files them on the
-- business axis, and these rows say they are places (as `segment_member` does for SEC filers).
insert into market.segment_member (member_code, kind, country_iso2, label) values
  ('edinet:日本', 'geography', 'JP', 'Japan'),
  ('edinet:国内', 'geography', 'JP', 'Japan (domestic)'),
  ('edinet:本邦', 'geography', 'JP', 'Japan'),
  ('edinet:米国', 'geography', 'US', 'United States'),
  ('edinet:中国', 'geography', 'CN', 'China'),
  ('edinet:韓国', 'geography', 'KR', 'South Korea'),
  ('edinet:台湾', 'geography', 'TW', 'Taiwan'),
  ('edinet:香港', 'geography', 'HK', 'Hong Kong'),
  ('edinet:インド', 'geography', 'IN', 'India'),
  ('edinet:タイ', 'geography', 'TH', 'Thailand'),
  ('edinet:ドイツ', 'geography', 'DE', 'Germany'),
  ('edinet:英国', 'geography', 'GB', 'United Kingdom'),
  ('edinet:フランス', 'geography', 'FR', 'France'),
  ('edinet:カナダ', 'geography', 'CA', 'Canada'),
  ('edinet:北米', 'geography', null, 'North America'),
  ('edinet:米州', 'geography', null, 'Americas'),
  ('edinet:南北アメリカ', 'geography', null, 'Americas'),
  ('edinet:中南米', 'geography', null, 'Latin America'),
  ('edinet:欧州', 'geography', null, 'Europe'),
  ('edinet:アジア', 'geography', null, 'Asia'),
  ('edinet:東アジア', 'geography', null, 'East Asia'),
  ('edinet:東南アジア', 'geography', null, 'Southeast Asia'),
  ('edinet:オセアニア', 'geography', null, 'Oceania'),
  ('edinet:海外', 'geography', null, 'Outside Japan')
on conflict (member_code) do nothing;
