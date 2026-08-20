-- A venue larger than 15,000 cannot be enumerated in one query — IDEMPOTENT.
--
-- OpenFIGI `/v3/filter` reports the true `total` but stops PAGING at 15,000. Measured 2026-08-14:
--
--   exchCode US, securityType2 'Common Stock'        total 20,107   we hold exactly 15,000
--   exchCode US, securityType2 'Depositary Receipt'  total  2,700   we hold 0 (see migration 53)
--
-- So ~5,100 US common stocks are unreachable by enumerating the venue, and the sweep recorded
-- itself as finished because the cursor simply ran out — a silent ceiling, not an error.
--
-- WHAT WAS TRIED AND REJECTED. `micCode` looks like the natural subdivision and is not one:
-- `XNYS` reports **37,787** — more than `exchCode: US` — and `XNAS` reports **0**. It is a
-- different taxonomy, not a partition of the same population.
--
-- A `query` prefix does work, and is bounded well under the ceiling:
--
--   query 'A' + exchCode US + Common Stock -> 1,410
--   query 'B' + exchCode US + Common Stock ->   247
--
-- 36 partitions (A-Z then 0-9 — tickers do begin with digits, e.g. Hong Kong's `0700`) each stay
-- far inside 15,000.
--
-- PARTITION ONLY WHEN IT IS NEEDED. Athens has 606 listings; sweeping it in 36 slices would be 36
-- requests to fetch what one gets, against a provider whose rate limit is the binding constraint on
-- everything here. The API reports `total` on the first page, so the resource can decide from data:
-- under the ceiling, sweep whole; over it, partition.

alter table market.exchange_cursor
  add column if not exists query_prefix text;

comment on column market.exchange_cursor.query_prefix is
  'The ticker prefix currently being enumerated, or NULL to sweep the venue whole. Set only when a venue+type exceeds OpenFIGI''s 15,000-row paging ceiling — Athens does not need slicing, the US does.';

-- The partitions, as data rather than a literal, so the alphabet is inspectable and changeable.
create table if not exists market.exchange_sweep_partition (
  prefix     text primary key,
  sort_order integer not null
);

insert into market.exchange_sweep_partition (prefix, sort_order)
select p, ord
from (
  select chr(64 + generate_series(1, 26)) as p, generate_series(1, 26) as ord
  union all
  -- DIGITS TOO. Hong Kong tickers are numeric (`0700`), as are Tokyo's (`7203`), so a letters-only
  -- alphabet would silently miss whole exchanges.
  select (generate_series(0, 9))::text, 26 + generate_series(1, 10)
) x
on conflict (prefix) do update set sort_order = excluded.sort_order;

grant select, insert, update, delete on market.exchange_sweep_partition to service_role;
grant select on market.exchange_sweep_partition to anon, authenticated;

-- The US is known to exceed the ceiling and has already been swept to exactly 15,000, so it starts
-- partitioned rather than re-running the whole-venue query to rediscover that. ONE-SHOT: migrations
-- re-run every deploy, and resetting the US cursor each time would restart its sweep forever.
do $$
begin
  if exists (select 1 from market.one_shot where key = '54-partition-the-us-sweep') then
    return;
  end if;

  update market.exchange_cursor
     set query_prefix = 'A', next_cursor = null, security_type = 'Common Stock'
   where exch_code = 'US';

  insert into market.one_shot (key, reason) values
    ('54-partition-the-us-sweep',
     'US holds exactly 15,000 of 20,107 common stocks — OpenFIGI pages no deeper. Restarted partitioned so the remaining ~5,100 and the 2,700 ADRs can be reached.');
end $$;

notify pgrst, 'reload schema';
