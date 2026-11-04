-- A QUARTER COMPUTED FROM YEAR-TO-DATE FACTS IS ITS OWN SOURCE (decided by the user 2026-11-04).
--
-- A 10-Q states the cash-flow statement year to date, so SEC's quarterly cash flow was mostly Q1.
-- Measured on production 2026-11-02, `sec-xbrl` cash rows: Q1 37,780, Q2 17,247, Q3 16,420. The
-- Q2/Q3 rows that exist average 1.4 lines; operating cash flow is in 956 of 17,247. So a SEC filer's
-- TTM free cash flow could come only from Yahoo's five quarters.
--
-- muffin-ingest's SEC lane now computes Q2 = H1 - Q1 and Q3 = 9M - H1 in stage 2 (`sec_facts`), for
-- a quarterly filer's money lines, where the filer states no three-month figure. Both terms come
-- from one concept, each its latest filing. The rows carry `sec-xbrl-ytd`, so a computed row says
-- it was computed. Measured on the captured filers, every computed quarter that can be checked
-- against a stated one agrees (Apple 8, Costco 2, Bristow 22, Bristow within one rounding unit).
--
-- PRIORITY 45: below a provider's stated figure (`yfinance` 100), as `derived-q4` (40) is, so at the
-- metric level a stated line always wins and a computed one fills only what nothing states. Above
-- `derived-q4`, though the two never meet: that one is a fourth quarter, this one a second or third.
--
-- THE DERIVATION READS A ROW THROUGH `metric_source_field`, keyed by source, so the computed rows
-- need the same income and cash mappings as `sec-xbrl`: a copy, held equal by
-- tests/a-computed-quarter-is-read-like-the-figure-it-replaces.sql. Balance lines are instants and
-- are never computed.

insert into market.data_source (code, name, priority) values
  ('sec-xbrl-ytd', 'SEC company facts: a quarter computed from year-to-date facts', 45)
on conflict (code) do update set name = excluded.name, priority = excluded.priority;

insert into market.metric_source_field (metric_code, source_code, statement, field)
select metric_code, 'sec-xbrl-ytd', statement, field
  from market.metric_source_field
 where source_code = 'sec-xbrl' and statement in ('income', 'cash')
on conflict (metric_code, source_code) do update
  set statement = excluded.statement, field = excluded.field;
