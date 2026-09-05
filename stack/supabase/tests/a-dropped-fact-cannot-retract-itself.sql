-- A DROPPED FACT CANNOT RETRACT ITSELF, AND THE TWO RULES OF MIGRATION 176 HAVE OPPOSITE FATES.
--
-- `security_segment` is written by upsert, so the parser only ever adds or overwrites. A member it
-- DEMOTES (residual -> partition 0) is still emitted and overwrites its own row on the next read.
-- A member it DROPS (a subtotal, discarded before it becomes a fact) is never touched again, so the
-- last row written survives for ever in a SERVED partition — the double count the rule exists to
-- prevent, now permanent. Measured on production the moment 176 shipped: 33 rows of
-- `ReportableSegmentAggregationBeforeOtherOperatingSegmentMember` and 8 of `OperatingSegmentsMember`
-- sat at partition 1.
--
-- APPLYING A REPAIR TO AN EMPTY DATABASE PROVES NOTHING — its statements match zero rows and every
-- guard inside goes unexercised, which is how migration 38 reached production. So this seeds the
-- production shape and runs the real migration over it.
--
-- THE FIXTURE MAKES THE CANDIDATE REPAIRS DISAGREE. Four shapes, and each plausible shortcut breaks
-- one of them:
--   subtotal alone in a split          -> DELETED    ("demote everything" leaves an unwritable row)
--   residual as the whole of a split   -> DEMOTED    ("delete everything" discards a filed fact)
--   residual BESIDE real segments      -> UNTOUCHED  ("purge residuals" destroys a correct split)
--   real segments, no residual at all  -> UNTOUCHED  (the control that must never move)
-- The third is the one that matters: it is Chevron's `depreciation`, which needs its residual to
-- reconcile, and a repair that cannot tell it from the second is worse than no repair.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Periodia','ZW',false)
  on conflict (iso2) do nothing;
insert into market.currency (code) values ('USD') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000017701','T177 Chevronish Inc','equity','ZW')
on conflict do nothing;

insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code) values
  ('00000000-0000-0000-0000-000000017701','0000000177-25-000001','10-K',date '2026-02-01','sec-segments')
on conflict do nothing;

-- The repair reads `segment_member_class`, which migration 176 seeds. Asserting the classes are
-- present first: if the seed were missing the repair would match nothing and "pass" vacuously.
do $$ begin
  if (select count(*) from market.segment_member_class where class = 'subtotal') = 0
     or (select count(*) from market.segment_member_class where class = 'residual') = 0 then
    raise exception 'segment_member_class is not seeded — the repair below would match nothing';
  end if;
end $$;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code, accession_number, reconciled_to) values
  -- (1) a SUBTOTAL served beside its own children. Must be DELETED outright.
  ('00000000-0000-0000-0000-000000017701','us-gaap:StatementBusinessSegmentsAxis','us-gaap:OperatingSegmentsMember','revenue','annual',date '2025-12-31',231370,'USD',1,'sec-segments','0000000177-25-000001',231370),
  -- (2) a RESIDUAL as the whole of a split. Must be DEMOTED to 0, keeping the filed value.
  ('00000000-0000-0000-0000-000000017701','us-gaap:StatementBusinessSegmentsAxis','us-gaap:AllOtherSegmentsMember','revenue','annual',date '2025-12-31',581,'USD',1,'sec-segments','0000000177-25-000001',231370),
  -- (3) the SAME residual beside real segments, in a different metric. Must be UNTOUCHED — this is
  --     Chevron's depreciation, where 283 + 18445 + 1404 = 20132 only reconciles WITH it.
  ('00000000-0000-0000-0000-000000017701','us-gaap:StatementBusinessSegmentsAxis','us-gaap:AllOtherSegmentsMember','depreciation','annual',date '2025-12-31',283,'USD',1,'sec-segments','0000000177-25-000001',20132),
  ('00000000-0000-0000-0000-000000017701','us-gaap:StatementBusinessSegmentsAxis','x:UpstreamMember','depreciation','annual',date '2025-12-31',18445,'USD',1,'sec-segments','0000000177-25-000001',20132),
  ('00000000-0000-0000-0000-000000017701','us-gaap:StatementBusinessSegmentsAxis','x:DownstreamMember','depreciation','annual',date '2025-12-31',1404,'USD',1,'sec-segments','0000000177-25-000001',20132),
  -- (4) real segments with no residual at all. The control.
  ('00000000-0000-0000-0000-000000017701','us-gaap:StatementBusinessSegmentsAxis','x:UpstreamMember','total_assets','annual',date '2025-12-31',256975,'USD',1,'sec-segments','0000000177-25-000001',312218),
  ('00000000-0000-0000-0000-000000017701','us-gaap:StatementBusinessSegmentsAxis','x:DownstreamMember','total_assets','annual',date '2025-12-31',55243,'USD',1,'sec-segments','0000000177-25-000001',312218)
on conflict do nothing;

-- The one-shot has already run against the real database by the time the suite executes, so its
-- guard would skip this fixture entirely. Clearing the key is what makes the migration RUN here.
delete from market.one_shot where key = 'retract-subtotals-and-residual-only-splits';

\i stack/supabase/migrations/177-a-dropped-fact-cannot-retract-itself.sql

do $$
declare
  n_subtotal int;
  n_residual_alone int;
  n_dep int;
  dep_sum numeric;
  dep_target numeric;
  n_assets int;
begin
  select count(*) into n_subtotal from market.security_segment
   where security_id = '00000000-0000-0000-0000-000000017701'
     and member_code = 'us-gaap:OperatingSegmentsMember';
  if n_subtotal <> 0 then
    raise exception 'a subtotal survived the repair: % row(s) still present', n_subtotal;
  end if;

  select count(*) into n_residual_alone from market.security_segment
   where security_id = '00000000-0000-0000-0000-000000017701'
     and metric_code = 'revenue' and partition_id > 0;
  if n_residual_alone <> 0 then
    raise exception 'a residual-only split is still served: % row(s)', n_residual_alone;
  end if;

  -- DEMOTED, NOT DELETED: the filing does state this value and a re-read still emits it at 0.
  if not exists (
    select 1 from market.security_segment
     where security_id = '00000000-0000-0000-0000-000000017701'
       and metric_code = 'revenue' and member_code = 'us-gaap:AllOtherSegmentsMember'
       and partition_id = 0 and value = 581 and reconciled_to is null
  ) then
    raise exception 'the residual-only row was deleted or left with a target, not demoted';
  end if;

  -- THE ONE THAT MATTERS: a residual beside real segments is a correct split, untouched.
  select count(*), sum(value), min(reconciled_to) into n_dep, dep_sum, dep_target
    from market.security_segment
   where security_id = '00000000-0000-0000-0000-000000017701'
     and metric_code = 'depreciation' and partition_id = 1;
  if n_dep <> 3 or dep_sum <> 20132 or dep_target <> 20132 then
    raise exception 'a residual beside real segments was disturbed: % rows summing % against %',
      n_dep, dep_sum, dep_target;
  end if;

  select count(*) into n_assets from market.security_segment
   where security_id = '00000000-0000-0000-0000-000000017701'
     and metric_code = 'total_assets' and partition_id = 1;
  if n_assets <> 2 then
    raise exception 'the no-residual control was disturbed: % rows', n_assets;
  end if;
end $$;

rollback;
