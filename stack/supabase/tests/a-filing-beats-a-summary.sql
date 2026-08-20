-- A FILING BEATS A PROVIDER'S SUMMARY, AND THE ORDER OF THE CRON MUST NOT DECIDE IT.
--
-- WHY THIS IS A TEST. `security_metric` is written by two resources on the same primary key:
-- `security-metrics` derives from yfinance/SEC statement documents, and `security-xbrl` writes
-- straight from the filer's own XBRL facts — seventeen years including quarterly, against
-- yfinance's four annual periods.
--
-- Both upsert with `do update`. Whichever ran last would win, so the number served for a period
-- would depend on cron ordering — and the usual loser is the better source, because
-- `security-metrics` re-derives on every run while `security-xbrl` refreshes monthly. The symptom
-- is a chart that silently shortens and a value that changes without anything having changed.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZR','Filerland','ZR',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009501', 'T95 Filer', 'equity', 'ZR')
on conflict (security_id) do nothing;

do $$
declare v numeric; sc text; n integer;
begin
  -- 1. THE PRIORITIES ARE ORDERED THE WAY THE ARGUMENT REQUIRES. Asserted rather than assumed:
  --    the whole rule reduces to these numbers, and a seed that reordered them would invert it
  --    while every other check still passed.
  if not (market.source_priority('sec-xbrl') > market.source_priority('sec')
          and market.source_priority('sec') > market.source_priority('yfinance')
          and market.source_priority('yfinance') > market.source_priority('derived')) then
    raise exception
      'source priority is not sec-xbrl > sec > yfinance > derived (got %, %, %, %) — a filing must outrank a provider summary, and arithmetic must outrank nothing',
      market.source_priority('sec-xbrl'), market.source_priority('sec'),
      market.source_priority('yfinance'), market.source_priority('derived');
  end if;

  -- 2. THE FILING SURVIVES A LATER PROVIDER WRITE. This is the ordering hazard itself.
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code)
  values ('00000000-0000-0000-0000-000000009501','revenue','annual',date '2024-12-31',
          1000, 'USD', 'sec-xbrl');

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code)
  values ('00000000-0000-0000-0000-000000009501','revenue','annual',date '2024-12-31',
          777, 'USD', 'yfinance')
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);

  select value, source_code into v, sc from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009501' and metric_code='revenue';
  if v is distinct from 1000 or sc is distinct from 'sec-xbrl' then
    raise exception
      'a yfinance write replaced the filing (% from %) — whichever resource ran last would win, and the served number would depend on cron ordering', v, sc;
  end if;

  -- 3. AND THE FILING STILL OVERWRITES ITSELF. A restatement must land; `>=` rather than `>` is
  --    what lets a source correct its own earlier answer.
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code)
  values ('00000000-0000-0000-0000-000000009501','revenue','annual',date '2024-12-31',
          1100, 'USD', 'sec-xbrl')
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);

  select value into v from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009501' and metric_code='revenue';
  if v is distinct from 1100 then
    raise exception 'a restatement from the SAME source did not land (%) — `>` instead of `>=` freezes a source at its first answer', v;
  end if;

  -- 4. AN UNKNOWN SOURCE OUTRANKS NOTHING. `source_priority` returns 0 for a code the table has
  --    never seen, so a typo cannot silently outrank a filing.
  if market.source_priority('not-a-real-source') <> 0 then
    raise exception 'an unknown source code has a non-zero priority — a typo would outrank a filing';
  end if;

  -- 5. THE CONCEPT CATALOGUE COVERS EVERY REPORTED METRIC. A metric with no concept is invisible
  --    to the XBRL path, silently: it simply never appears, and the chart is merely shorter.
  select count(*) into n
    from market.metric m
   where not m.is_derived
     and not exists (select 1 from market.xbrl_concept c where c.metric_code = m.code);
  if n <> 0 then
    raise exception '% reported metrics have no XBRL concept — they are invisible to the filer path with no error anywhere', n;
  end if;

  -- 6. AND EVERY CONCEPT NAMES A REAL METRIC. Guarded by the foreign key, asserted here so the
  --    two halves of the catalogue are checked in one place.
  select count(*) into n from market.xbrl_concept c
   where not exists (select 1 from market.metric m where m.code = c.metric_code);
  if n <> 0 then
    raise exception '% xbrl concepts name a metric that does not exist', n;
  end if;
end $$;

rollback;

\echo 'ok: a filing outranks a provider summary, and every reported metric is reachable from XBRL'
