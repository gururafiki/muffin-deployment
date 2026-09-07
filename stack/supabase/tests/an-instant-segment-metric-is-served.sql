-- AN INSTANT CANNOT GO THROUGH THE PIVOT, AND A COLUMN NOTHING FILLS IS NOT A FEATURE.
--
-- `security_segment_current` aggregates DURATION facts into one row per (security, axis, member)
-- and pivots the metrics into columns. An INSTANT has no duration to group with, so `total_assets`
-- has always been fetched by a separate lateral — and migration 196 adds two more of the same
-- shape: `long_lived_assets` (ASC 280 requires it beside geographic revenue; Amazon reports US
-- $180,000,000,000 and non-US $61,300,000,000) and `goodwill` (per segment, which is where
-- impairment is tested).
--
-- WHY THIS IS A TEST. The failure is silent in both directions. A metric added to `xbrl_concept`
-- but not to the view's laterals is parsed, stored and never served — migration 56's inert column,
-- exactly. And a lateral that drops its `period_ending <= p.period_ending` bound reports a LATER
-- balance-sheet date against an EARLIER income statement, which is a wrong number that looks
-- entirely ordinary.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE: the member carries TWO instants, an older one
-- matching its revenue period and a newer one after it. A lateral without the bound takes the
-- newer; the correct one takes the older.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000019601', 'T196 Instant Inc', 'equity')
on conflict (security_id) do nothing;

insert into market.security_segment
  (security_id, accession_number, axis, member_code, metric_code, period_type,
   period_start, period_ending, value, currency_code, partition_id, source_code) values
  -- The duration fact that gives the member its row and its period.
  ('00000000-0000-0000-0000-000000019601','T196-1','srt:StatementGeographicalAxis','country:US',
   'revenue','annual', date '2022-01-01', date '2022-12-31', 100000, 'USD', 1, 'sec'),
  -- The instants. The FIRST matches the revenue period; the SECOND is a year later and must NOT
  -- be chosen, or a later balance sheet is reported against an earlier income statement.
  ('00000000-0000-0000-0000-000000019601','T196-1','srt:StatementGeographicalAxis','country:US',
   'long_lived_assets','instant', date '2022-12-31', date '2022-12-31', 180000, 'USD', 1, 'sec'),
  ('00000000-0000-0000-0000-000000019601','T196-1','srt:StatementGeographicalAxis','country:US',
   'long_lived_assets','instant', date '2023-12-31', date '2023-12-31', 999999, 'USD', 1, 'sec'),
  -- DELIBERATELY AN EARLIER DATE THAN THE LONG-LIVED-ASSETS INSTANT. With both on 2022-12-31 the
  -- two laterals TIE, and a mutation deleting a lateral's `metric_code` filter picked the right row
  -- by chance and passed — the tied-sort-key trap. At 2022-06-30 an unfiltered lateral
  -- deterministically takes the later long_lived_assets row instead, so the filter is load-bearing.
  ('00000000-0000-0000-0000-000000019601','T196-1','srt:StatementGeographicalAxis','country:US',
   'goodwill','instant', date '2022-06-30', date '2022-06-30', 12527, 'USD', 1, 'sec')
on conflict do nothing;

do $$
declare lla numeric; gw numeric; ta numeric;
begin
  select c.long_lived_assets, c.goodwill, c.total_assets into lla, gw, ta
    from market.security_segment_current c
   where c.security_id = '00000000-0000-0000-0000-000000019601'
     and c.member_code = 'country:US';

  if lla is null then
    raise exception 'long_lived_assets is not served — the metric is parsed and stored and the '
                    'view has no lateral for it, which is migration 56''s inert column again';
  end if;
  if lla <> 180000 then
    raise exception 'long_lived_assets is % rather than 180000 — the lateral took the LATER '
                    'instant, so a balance sheet a year after the income statement is being '
                    'reported beside it', lla;
  end if;
  if gw is distinct from 12527 then
    raise exception 'goodwill is not served (got %) — added to xbrl_concept without a lateral is '
                    'parsed, stored and invisible', coalesce(gw::text, 'null');
  end if;
  -- THE CONTROL. `total_assets` has no fact here, so it must be NULL rather than borrowing
  -- another metric's instant — which is what a lateral missing its `metric_code` filter would do.
  if ta is not null then
    raise exception 'total_assets is % for a member that has no total_assets fact — a lateral is '
                    'matching on something other than the metric', ta;
  end if;

  raise notice 'ok  instant segment metrics are served, bounded by the member''s own period';
end $$;

rollback;
