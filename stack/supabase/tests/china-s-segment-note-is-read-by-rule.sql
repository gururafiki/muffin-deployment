-- China's segment note is read by rule (migration 20261127200000). THE TEST RUNS THE MIGRATION
-- ITSELF, from the state before it: its re-queue is a one-shot, so a mutated copy applied on top of
-- a database where it already ran would change nothing and prove nothing.
--
-- THE FIXTURE MAKES THE CANDIDATE RE-QUEUES DISAGREE. Only A is due again:
--   A  a FY2025 full report read into no rows           -> re-queued (the note may read it)
--   B  a FY2025 full report holding rows                -> untouched (the note never runs on it)
--   C  a FY2022 full report read into no rows           -> untouched (filed before 2024)
--   D  a FY2025 summary (年度报告摘要) read into no rows -> untouched (not the full report)
--   E  a FY2025 PDF another regulator filed, no rows    -> untouched (another regulator)
--   F  a FY2025 full report never read                  -> untouched (already due)
--   G  a FY2025 full report filed as a web page         -> untouched (not a PDF the reader reads)
-- E and G carry CNINFO's report type on purpose, so the source and the PDF test are each the only
-- thing excluding them. The axis is deleted first: the migration inserts it idempotently, and a
-- row left by an earlier apply would hide its removal.

\set ON_ERROR_STOP on

begin;

delete from market.one_shot where key = 'cninfo-requeue-no-rows-for-the-note-2026-11-27';
delete from market.segment_note_rule where regulator = 'cninfo';
delete from market.segment_axis where axis = 'cninfo:经营分部';

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Periodia','ZW',false)
  on conflict (iso2) do nothing;
insert into market.currency (code) values ('CNY') on conflict do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000020112711','T2011 China Bank','equity','ZW')
on conflict do nothing;

insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code,
   segments_parsed_at, segments_parser_version) values
  ('00000000-0000-0000-0000-000020112711','https://x/a.PDF','年度报告',date '2026-03-28','cninfo',now(),20),
  ('00000000-0000-0000-0000-000020112711','https://x/b.PDF','年度报告',date '2026-03-29','cninfo',now(),20),
  ('00000000-0000-0000-0000-000020112711','https://x/c.PDF','年度报告',date '2023-03-28','cninfo',now(),20),
  ('00000000-0000-0000-0000-000020112711','https://x/d.PDF','年度报告摘要',date '2026-03-28','cninfo',now(),20),
  ('00000000-0000-0000-0000-000020112711','https://x/e.PDF','年度报告',date '2026-03-28','sec-submissions',now(),20),
  ('00000000-0000-0000-0000-000020112711','https://x/g.html','年度报告',date '2026-03-28','cninfo',now(),20),
  ('00000000-0000-0000-0000-000020112711','https://x/f.PDF','年度报告',date '2026-03-30','cninfo',null,null)
on conflict do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code, accession_number, reconciled_to) values
  ('00000000-0000-0000-0000-000020112711','cninfo:分行业','cninfo:甲','revenue','annual',date '2025-12-31',60,'CNY',1,'cninfo','https://x/b.PDF',100),
  ('00000000-0000-0000-0000-000020112711','cninfo:分行业','cninfo:乙','revenue','annual',date '2025-12-31',40,'CNY',1,'cninfo','https://x/b.PDF',100);

\i stack/supabase/migrations/20261127200000_china_s_segment_note_is_read_by_rule.sql

do $$
declare
  due text;
  label text;
begin
  select string_agg(accession_number, ',' order by accession_number) into due
    from market.security_filing
   where security_id = '00000000-0000-0000-0000-000020112711' and segments_parser_version = 0;
  if due is distinct from 'https://x/a.PDF' then
    raise exception 'only the recent full report read into no rows must be re-queued; re-queued: %', due;
  end if;
  if (select segments_parser_version from market.security_filing
       where accession_number = 'https://x/f.PDF') is not null then
    raise exception 'a report never read must be left as it was';
  end if;

  -- The vocabulary the lane reads: every role the reader needs, and the labels it must tell apart.
  foreach label in array array['营业收入', '对外交易收入', '其中:对外交易收入', '营业收入合计'] loop
    if (select role from market.segment_note_rule
         where regulator = 'cninfo' and rule = 'label' and label ~ pattern
         order by priority desc limit 1) is distinct from 'revenue' then
      raise exception 'the cninfo label % must read as revenue', label;
    end if;
  end loop;
  if (select role from market.segment_note_rule
       where regulator = 'cninfo' and rule = 'label' and '合计' ~ pattern
       order by priority desc limit 1) is distinct from 'total' then
    raise exception '合计 must read as the total column';
  end if;
  if (select role from market.segment_note_rule
       where regulator = 'cninfo' and rule = 'label' and '其他业务及合并抵销' ~ pattern
       order by priority desc limit 1) is not null then
    raise exception '其他业务及合并抵销 is a member: without it Ping An''s split does not add up';
  end if;
  if (select role from market.segment_note_rule
       where regulator = 'cninfo' and rule = 'label' and '减:分部间交易收入' ~ pattern
       order by priority desc limit 1) is distinct from 'skip' then
    raise exception 'an intersegment row must be skipped';
  end if;
  if (select role from market.segment_note_rule
       where regulator = 'cninfo' and rule = 'heading' and '(1)经营分部' ~ pattern
       order by priority desc limit 1) is distinct from 'business' then
    raise exception 'the operating-segment heading must name a business table';
  end if;
  if (select role from market.segment_note_rule
       where regulator = 'cninfo' and rule = 'label' and '未分配部分' ~ pattern
       order by priority desc limit 1) is not null then
    raise exception '未分配部分 is a member: SF Holding''s carries external revenue';
  end if;
  foreach label in array array['境内', '中国香港澳门台湾', '长三角地区', '其他国家和地区'] loop
    if not exists (select 1 from market.segment_note_rule
                    where regulator = 'cninfo' and rule = 'member' and role = 'geography'
                      and label ~ pattern) then
      raise exception '% must read as a place, or a geographic table reads as business', label;
    end if;
  end loop;
  if exists (select 1 from market.segment_note_rule
              where regulator = 'cninfo' and rule = 'member' and '公司金融业务' ~ pattern) then
    raise exception 'a business line must not read as a place';
  end if;
  if not exists (select 1 from market.segment_axis
                  where axis = 'cninfo:经营分部' and taxonomy = 'cninfo' and kind = 'business') then
    raise exception 'the note''s axis must exist, or security_segment_current drops its rows';
  end if;
end $$;

\echo ok: China's segment note is read by rule; only recent reports read into no rows are re-queued

rollback;
