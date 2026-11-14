-- A PERIOD END IS A QUARTER OR A HALF-YEAR, NEVER BOTH (decided by the user 2026-11-14).
--
-- Yahoo's quarterly series is read as quarters or half-years by its cadence (muffin-ingest
-- `statements.cadence`). The edge's `security-quarters` filed half-years as quarters, and the
-- lane's cadence can flip between visits, and neither write retracted the other. So one yfinance
-- period end could hold both a `quarter` and a `half` row, and the derivation and the quarterly
-- tables read six months as three. muffin-ingest#178 makes the lane retract the other type at
-- every key it writes; this repairs what is already stored, which the lane alone cannot reach:
-- Yahoo's window no longer holds the older periods.
--
-- THE CLASS IS THE LANE'S OWN RULE. `cadence` reads the union of a company's quarterly period ends
-- across its statements: half-yearly only if every gap is 170-195 days. Here, a security holding a
-- yfinance `half` row is QUARTERLY if any two consecutive quarter/half period ends, across all its
-- statements, are under 170 days apart, and HALF-YEARLY otherwise. The note measured the classes
-- per statement (docs/deferred/2026-10-10-the-edge-s-half-years-filed-as-quarters.md); for 8
-- securities the two differ (half-year balance sheets beside quarter-end income stubs), and a
-- per-statement repair there would be undone at the lane's next visit. Measured 2026-11-14 in a
-- read-only transaction, by the rule used here:
--   * A1, half-yearly: 1,139 securities holding 2,506 `quarter` rows, 1,978 of them beside a `half`
--     twin. The twins are deleted. The other 528 are periods older than Yahoo's window (NESN.SW and
--     CBA.AX each keep one): they are re-filed as `half`, so the older balance sheets are kept.
--   * A2, quarterly: 19 securities holding 59 `half` rows beside a `quarter` twin (1419.T: Yahoo
--     first listed three period ends 180 days apart, a week later seven, 90 days apart). Those
--     `half` rows are deleted.
--
-- RE-FILED BY INSERT AND DELETE, NOT BY UPDATE. The delete fires `security_statement_retract`,
-- which removes the `quarter` metrics derived from the row and re-queues what remains; the new
-- `half` row has no `derived_at`, so the derivation reads it. An update of `period_type` fires
-- neither (`security_statement_requeue` watches `data` and `as_of`), and would leave the quarter
-- metrics standing beside a row that no longer says quarter.
--
-- Annual rows and every other source's rows are never touched. Runs once: post-baseline migrations
-- are applied by version, and the key below makes a re-apply a no-op as well.

do $$
declare
  twins int;
  refiled int;
  wrong_halves int;
begin
  if exists (select 1 from market.one_shot where key = 'yahoo-half-twins-2026-11-14') then
    raise notice 'yahoo-half-twins: already applied';
    return;
  end if;

  -- THE CLASS OF EACH SECURITY IS TAKEN BEFORE ANYTHING CHANGES: every step below changes the
  -- period ends it is computed from.
  drop table if exists pg_temp.half_class;
  create temporary table half_class on commit drop as
  with q as (
    select security_id, statement, period_ending, period_type
      from market.security_statement
     where source_code = 'yfinance' and period_type in ('quarter', 'half')
  ),
  ends as (select distinct security_id, period_ending from q),
  gaps as (
    select security_id,
           period_ending - lag(period_ending) over (partition by security_id
                                                    order by period_ending) as gap
      from ends
  )
  select h.security_id,
         exists (select 1 from gaps g where g.security_id = h.security_id and g.gap < 170)
           as quarterly
    from (select distinct security_id from q where period_type = 'half') h;

  -- A1: a half-yearly security's quarter row beside its half twin.
  delete from market.security_statement s
   using half_class c
   where c.security_id = s.security_id
     and not c.quarterly
     and s.source_code = 'yfinance'
     and s.period_type = 'quarter'
     and exists (select 1 from market.security_statement t
                  where t.security_id = s.security_id and t.source_code = s.source_code
                    and t.statement = s.statement and t.period_ending = s.period_ending
                    and t.period_type = 'half');
  get diagnostics twins = row_count;

  -- A1: its quarter rows with no twin, re-filed as half.
  insert into market.security_statement
    (security_id, statement, period_ending, period_type, currency, data, source_code, as_of)
  select s.security_id, s.statement, s.period_ending, 'half', s.currency, s.data, s.source_code,
         s.as_of
    from market.security_statement s
    join half_class c on c.security_id = s.security_id and not c.quarterly
   where s.source_code = 'yfinance' and s.period_type = 'quarter'
  on conflict do nothing;
  get diagnostics refiled = row_count;

  delete from market.security_statement s
   using half_class c
   where c.security_id = s.security_id
     and not c.quarterly
     and s.source_code = 'yfinance'
     and s.period_type = 'quarter';

  -- A2: a quarterly security's half row beside its quarter twin.
  delete from market.security_statement s
   using half_class c
   where c.security_id = s.security_id
     and c.quarterly
     and s.source_code = 'yfinance'
     and s.period_type = 'half'
     and exists (select 1 from market.security_statement t
                  where t.security_id = s.security_id and t.source_code = s.source_code
                    and t.statement = s.statement and t.period_ending = s.period_ending
                    and t.period_type = 'quarter');
  get diagnostics wrong_halves = row_count;

  insert into market.one_shot (key, reason) values (
    'yahoo-half-twins-2026-11-14',
    format('deleted %s quarter twins and %s half twins; re-filed %s quarters as half',
           twins, wrong_halves, refiled));
  raise notice 'yahoo-half-twins: deleted % quarter twins, % half twins; re-filed % as half',
    twins, wrong_halves, refiled;
end $$;
