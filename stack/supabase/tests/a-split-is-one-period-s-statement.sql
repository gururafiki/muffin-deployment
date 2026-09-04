-- A SPLIT IS ONE PERIOD'S STATEMENT, AND UNIONING TWO OF THEM INVENTS A COMPANY.
--
-- WHY. `security_segment_current` picked the newest period PER MEMBER
-- (`distinct on (security_id, axis, member_code, metric_code) order by period_ending desc`), so
-- every member spelling a filer had ever used survived, each at its own newest year, and the view
-- served a split no filing ever reported. Measured in production 2026-09-02, on the day the stock
-- page first read it: Apple's business-segments axis returned 25 members spanning 2008..2025
-- summing 627.3bn against a true FY2025 416.2bn, and Shell's product split reached 1,201bn against
-- a revenue of 266.9bn. 129 of 216 (security, axis) groups spanned more than one period — 83 of the
-- 104 securities that have segments at all.
--
-- This is migration 150's ASML lesson one level up. There, two FILINGS of one period disagreed
-- about member names (`asml:EuvMember` -> `asml:NXEMember`) and `dense_rank` fixed it by choosing a
-- whole filing rather than a row. Here it is two PERIODS and the rule is the same: choose the
-- period first, then take its members.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE, in row count AND in total.
--   newest-per-MEMBER (the defect): Alpha@2025=90, BetaOld@2024=60, Gamma@2025=60  -> 3 rows, 210
--   newest-per-(SECURITY, AXIS)   : Alpha@2025=90,                  Gamma@2025=60  -> 2 rows, 150
-- `x:AlphaMember` deliberately survives the rename, so the per-member de-duplication is still
-- exercised: it must appear ONCE, at its 2025 value, never twice and never at 2024's 40.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Periodia','ZW',false)
  on conflict (iso2) do nothing;
-- `market.currency` is filled by the ingest at RUNTIME, so USD does not exist on a fresh database.
insert into market.currency (code) values ('USD') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000016801','T168 Renamer Inc','equity','ZW'),
  -- The control: one period only. The fix must leave this shape completely alone.
  ('00000000-0000-0000-0000-000000016802','T168 Steady Inc','equity','ZW')
on conflict do nothing;

insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code) values
  ('00000000-0000-0000-0000-000000016801','0000000168-24-000001','10-K',date '2025-02-01','sec-segments'),
  ('00000000-0000-0000-0000-000000016801','0000000168-25-000001','10-K',date '2026-02-01','sec-segments'),
  ('00000000-0000-0000-0000-000000016802','0000000168-25-000002','10-K',date '2026-02-01','sec-segments')
on conflict do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code, accession_number, reconciled_to) values
  -- FY2024, as filed: Alpha 40 + BetaOld 60 = 100.
  ('00000000-0000-0000-0000-000000016801','srt:ProductOrServiceAxis','x:AlphaMember','revenue','annual',date '2024-12-31',40,'USD',1,'sec-segments','0000000168-24-000001',100),
  ('00000000-0000-0000-0000-000000016801','srt:ProductOrServiceAxis','x:BetaOldMember','revenue','annual',date '2024-12-31',60,'USD',1,'sec-segments','0000000168-24-000001',100),
  -- FY2025, as filed, after the filer renamed Beta to Gamma: Alpha 90 + Gamma 60 = 150.
  ('00000000-0000-0000-0000-000000016801','srt:ProductOrServiceAxis','x:AlphaMember','revenue','annual',date '2025-12-31',90,'USD',1,'sec-segments','0000000168-25-000001',150),
  ('00000000-0000-0000-0000-000000016801','srt:ProductOrServiceAxis','x:GammaMember','revenue','annual',date '2025-12-31',60,'USD',1,'sec-segments','0000000168-25-000001',150),
  -- The control company: a single period, two members, 30 + 70 = 100.
  ('00000000-0000-0000-0000-000000016802','srt:ProductOrServiceAxis','x:OneMember','revenue','annual',date '2025-12-31',30,'USD',1,'sec-segments','0000000168-25-000002',100),
  ('00000000-0000-0000-0000-000000016802','srt:ProductOrServiceAxis','x:TwoMember','revenue','annual',date '2025-12-31',70,'USD',1,'sec-segments','0000000168-25-000002',100),
  -- The NESTED level, same rename, same defect: a child's share is OF ITS PARENT, so a denominator
  -- summed across years is a percentage of something the filer never reported.
  ('00000000-0000-0000-0000-000000016801','srt:ProductOrServiceAxis','x:AlphaOldChildMember','revenue','annual',date '2024-12-31',10,'USD',1,'sec-segments','0000000168-24-000001',40),
  ('00000000-0000-0000-0000-000000016801','srt:ProductOrServiceAxis','x:AlphaNewChildMember','revenue','annual',date '2025-12-31',30,'USD',1,'sec-segments','0000000168-25-000001',90),
  ('00000000-0000-0000-0000-000000016801','srt:ProductOrServiceAxis','x:AlphaRestMember','revenue','annual',date '2025-12-31',60,'USD',1,'sec-segments','0000000168-25-000001',90)
on conflict do nothing;

-- The three nested rows above belong INSIDE `x:AlphaMember`; set that after insert so the flat
-- rows above keep `parent_member is null`.
update market.security_segment
   set parent_axis = 'srt:ProductOrServiceAxis', parent_member = 'x:AlphaMember'
 where security_id = '00000000-0000-0000-0000-000000016801'
   and member_code in ('x:AlphaOldChildMember','x:AlphaNewChildMember','x:AlphaRestMember');

do $$
declare
  n_rows   int;
  n_total  numeric;
  alpha    numeric;
  n_ctrl   int;
  ctrl_tot numeric;
  n_child  int;
  child_sh numeric;
begin
  select count(*), coalesce(sum(revenue), 0)
    into n_rows, n_total
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000016801'
     and axis = 'srt:ProductOrServiceAxis';

  if n_rows <> 2 then
    raise exception 'the flat split must be ONE period''s members: expected 2, got %', n_rows;
  end if;
  -- 210 is the exact number the defect produced. Naming it means a regression is recognisable
  -- rather than merely wrong.
  if n_total <> 150 then
    raise exception 'the split must sum to the period it was filed for: expected 150, got % (210 = the two periods unioned)', n_total;
  end if;

  select revenue into alpha
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000016801'
     and member_code = 'x:AlphaMember';
  if alpha is distinct from 90 then
    raise exception 'a member that survived the rename must be served at its NEWEST value: expected 90, got %', alpha;
  end if;

  if exists (select 1 from market.security_segment_current
              where security_id = '00000000-0000-0000-0000-000000016801'
                and member_code = 'x:BetaOldMember') then
    raise exception 'a member the filer stopped reporting must not survive into the current split';
  end if;

  -- THE GUARD MUST STAY SILENT ON THE INNOCENT SHAPE. A company with one period is not affected by
  -- any of this, and a fix that changed it would be a different bug.
  select count(*), coalesce(sum(revenue), 0) into n_ctrl, ctrl_tot
    from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000016802';
  if n_ctrl <> 2 or ctrl_tot <> 100 then
    raise exception 'a single-period filer must be untouched: got % rows summing %', n_ctrl, ctrl_tot;
  end if;

  -- The nested level, same rule.
  select count(*) into n_child
    from market.security_segment_detail
   where security_id = '00000000-0000-0000-0000-000000016801'
     and parent_member = 'x:AlphaMember';
  if n_child <> 2 then
    raise exception 'the nested split must be ONE period''s children: expected 2, got %', n_child;
  end if;

  select share_of_parent_pct into child_sh
    from market.security_segment_detail
   where security_id = '00000000-0000-0000-0000-000000016801'
     and member_code = 'x:AlphaNewChildMember';
  -- 30 of (30 + 60) = 33.33%. Under the defect the denominator also carries 2024's child, giving
  -- 30 of 100 = 30.00% — a plausible number that is quietly a percentage of nothing.
  if child_sh is null or abs(child_sh - 33.33) > 0.01 then
    raise exception 'a child''s share must be of its parent IN THAT PERIOD: expected 33.33, got %', child_sh;
  end if;

  raise notice 'ok  a split is one period''s statement (flat 2 rows/150, nested 2 rows, control untouched)';
end $$;

rollback;
