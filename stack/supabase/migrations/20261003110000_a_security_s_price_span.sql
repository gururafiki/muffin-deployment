-- The first and last bar each security holds, kept beside `price_bar` so nothing has to find them
-- by scanning it. Stage 1d of the umbrella's docs/specs/2026-09-26-finishing-the-universe-family.md.
--
-- WHY A TABLE. `coverage_current` and `security_facet_status` still answer "does this security have
-- its price history?" from `security.price_history_from` and `daily_history_from`, which the
-- retired edge resources wrote and nothing has written since the D2 cutover (2026-09-12). So the
-- two facets are frozen, and every security added since reads false. The obvious replacement,
-- `min(trade_date)` per security over `price_bar`, is the scan this repo already paid for once
-- (7.9 s, CLAUDE.md): 58 M rows in 61 yearly partitions, growing every night.
--
-- MEASURED 2026-09-30 on production, cold cache: the per-security probe below costs 9.3 s for 500
-- securities (15,666 blocks read), because finding the first bar walks the partitions upwards from
-- 1970 until it meets one. That is affordable for the 2,500 securities a night of the price sweep
-- touches, in chunks, and far too much for a view that anon reads. Hence a table, maintained by the Dagster
-- asset `security_price_span`, which calls the function below for the securities whose
-- `price_bar_history` partition materialised since its last run.
--
-- EXPAND FIRST. This migration adds the table and the function and changes no reader. The asset
-- bootstraps the table on its first run; the two facets are re-pointed at it in the next migration,
-- once it is full, so no coverage sample records a 0% that is only an empty table.
--
-- A ROW WITH NO DATES IS AN ANSWER. A security the history lane asked about and got nothing for is
-- stored with null dates, so "the lane has not reached it" (no row) and "the lane reached it and it
-- has no bars" (a row, nulls) stay different facts.
--
-- NO `bars` COLUMN, although the spec listed one. Counting a security's bars reads every one of its
-- ~7,300 rows, where the two dates are two index probes; nothing reads a count yet.

create table if not exists market.security_price_span (
  security_id uuid primary key references market.security on delete cascade,
  first_date  date,
  last_date   date,
  updated_at  timestamptz not null default now(),
  constraint security_price_span_ordered check (first_date <= last_date),
  constraint security_price_span_both_or_neither check ((first_date is null) = (last_date is null))
);

comment on table market.security_price_span is
  'The first and last trade_date each security holds in market.price_bar. Maintained by the Dagster '
  'asset security_price_span through market.derive_security_price_span(); a row with null dates means '
  'the history lane reached the security and it holds no bars.';

grant select, insert, update, delete on market.security_price_span to service_role, ingest_rw;
grant select on market.security_price_span to anon, authenticated;

alter table market.security_price_span enable row level security;
drop policy if exists security_price_span_public_read on market.security_price_span;
create policy security_price_span_public_read on market.security_price_span for select using (true);

create or replace function market.derive_security_price_span(p_security_ids uuid[])
returns jsonb
language plpgsql
set search_path to 'market', 'pg_catalog', 'pg_temp'
as $function$
declare
  v_asked   integer;
  v_written integer;
  v_empty   integer;
begin
  -- DISTINCT, because an upsert that meets one key twice fails the whole statement (SQLSTATE
  -- 21000), and a caller assembling ids from several materialisations can repeat one. And only
  -- securities that exist: an id deleted since its partition ran would otherwise fail the foreign
  -- key and take the batch with it.
  with asked as (
    select distinct a.id as security_id
      from unnest(p_security_ids) as a(id)
     where exists (select 1 from market.security s where s.security_id = a.id)
  ),
  -- Two index probes per security, not a scan: the primary key is (security_id, trade_date) in
  -- every yearly partition, so each end is a `limit 1` down that index.
  span as (
    select a.security_id, f.trade_date as first_date, l.trade_date as last_date
      from asked a
      left join lateral (select b.trade_date from market.price_bar b
                          where b.security_id = a.security_id
                          order by b.trade_date limit 1) f on true
      left join lateral (select b.trade_date from market.price_bar b
                          where b.security_id = a.security_id
                          order by b.trade_date desc limit 1) l on true
  ),
  written as (
    insert into market.security_price_span as ps (security_id, first_date, last_date, updated_at)
    select security_id, first_date, last_date, now() from span
    on conflict (security_id) do update
       set first_date = excluded.first_date,
           last_date  = excluded.last_date,
           updated_at = excluded.updated_at
     -- Cheap to re-run: an unchanged span is not rewritten.
     where (ps.first_date, ps.last_date) is distinct from (excluded.first_date, excluded.last_date)
    returning 1
  )
  select (select count(*) from asked),
         (select count(*) from written),
         (select count(*) from span where first_date is null)
    into v_asked, v_written, v_empty;

  return jsonb_build_object('asked', v_asked, 'written', v_written, 'without_bars', v_empty);
end;
$function$;

comment on function market.derive_security_price_span(uuid[]) is
  'Upserts market.security_price_span for the given securities from market.price_bar: the first and '
  'last trade_date, or nulls when a security holds no bars. Called by the Dagster asset '
  'security_price_span; returns counts.';

-- The worker calls it; nothing else should. Functions are executable by PUBLIC by default.
revoke execute on function market.derive_security_price_span(uuid[]) from public;
grant execute on function market.derive_security_price_span(uuid[]) to ingest_rw, service_role;
