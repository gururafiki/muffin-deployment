-- THE INSIDER SUMMARY COUNTS A TRADE ONCE, WHOEVER WROTE IT. Phase 5 of the umbrella's
-- docs/specs/2026-10-24-sec-family.md, before step 8's Form 4 backfill.
--
-- `insider_trade` has two writers for one fact:
--   - the edge `security-insider` resource (openbb per ticker), whose rows carry no accession;
--   - the Dagster SEC lanes (each day's Form 4s, and each quarter's insider data set), whose rows
--     do.
-- `security_insider_summary` counted every row in its 90-day window, so a trade both writers record
-- is counted twice: buys, sells, net shares and trades double, though the people counts do not.
-- Measured 2026-10-30, the 90-day window holds 34,811 edge rows over 1,514 securities, all of which
-- the Form 4 backfill would have doubled, and the edge still writes 4,000-10,000 rows a day. It is
-- the sectors' lesson again: a table two sources write needs its serving view to pick.
--
-- THE LANE COVERS WHOLE DAYS, SO THE VIEW PICKS BY DAY. A day the lane has collected holds every
-- Form 4 the index names for a tracked issuer, so an edge row filed that day says nothing the
-- lane's rows do not. The day is the FILING date, compared across all securities rather than per
-- security: a Form 4 accepted after 17:30 is in the next day's index, so openbb can date a filing
-- the day before the lane does. Asked per security, that one filing would be counted twice, once
-- on each side of the boundary.
--
-- When the edge's rows are deleted (step 11), the clause matches nothing and can go.
--
-- Guard: stack/supabase/tests/an-insider-trade-two-writers-record-is-counted-once.sql.

-- The days the lane has collected, read by the view below.
create index if not exists insider_trade_lane_filing_day
  on market.insider_trade (filing_date) where accession_number is not null;

-- Same columns in the same order, so the view keeps its grants.
create or replace view market.security_insider_summary as
with lane_days as materialized (
  -- A trade in the window was filed in it too, so the window bounds the days to read.
  select distinct filing_date
    from market.insider_trade
   where accession_number is not null
     and filing_date >= current_date - 90
)
select security_id,
       count(*) filter (where direction = 'Acquisition') as buys,
       count(*) filter (where direction = 'Disposition') as sells,
       count(distinct owner_name) filter (where direction = 'Acquisition') as buyers,
       count(distinct owner_name) filter (where direction = 'Disposition') as sellers,
       coalesce(sum(shares) filter (where direction = 'Acquisition'), 0)
         - coalesce(sum(shares) filter (where direction = 'Disposition'), 0) as net_shares,
       max(transaction_date) as latest,
       count(*) as trades
  from market.insider_trade t
 where transaction_date >= current_date - 90
   and (t.accession_number is not null
        or not exists (select 1 from lane_days d where d.filing_date = t.filing_date))
 group by security_id;
