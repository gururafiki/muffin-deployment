-- `exchange_cursor.listings` is a CACHE of a derivable count, and it had drifted to zero.
--
-- The sweep wrote `listings: written` unconditionally, so a run that fetched nothing overwrote the
-- venue's recorded total with 0. Measured 2026-08-14: OpenFIGI answered 429 on the first page,
-- `listExchange` broke out silently, and Japan's recorded 1,800 became 0 on a run that did no work.
-- The underlying rows were never touched — `exchange_listing` still held all 1,800 — so this is a
-- telemetry corruption rather than data loss, which is precisely why it went unnoticed: every
-- listing was still there and the number above them was wrong.
--
-- THE REAL LESSON IS THAT THE COLUMN IS REDUNDANT. `count(*) from exchange_listing where exch_code
-- = ...` is the same fact, always current, and cannot disagree with itself. The same fact in two
-- places WILL drift — that is why `market.exchange` replaced the venue map that lived in both
-- `exchanges.ts` and a seed. This column is kept for now because an operator reading
-- `exchange_cursor` wants the progress number beside the cursor rather than as a second query, but
-- it is a cache and should be treated as one: the resource now only writes it when a run actually
-- produced listings, and this resyncs what the old behaviour zeroed.
--
-- NOT one-shot. Re-deriving a cache from its source is idempotent by construction and correct on
-- every deploy — unlike the repairs in 55, 57 and 58, which each undo a specific past event and
-- would defeat their own purpose if they ran twice. A cache resync has no such asymmetry.

update market.exchange_cursor c
   set listings = t.n
  from (
    select exch_code, count(*) as n
      from market.exchange_listing
     group by exch_code
  ) t
 where t.exch_code = c.exch_code
   and c.listings is distinct from t.n;

-- A venue with a cursor row and no listings at all is legitimate — 16 had never been swept when
-- this was written (AU, JP, CN, ID, SE, GR, PE among them), because `exchange-listings` was never
-- on the cron. Those stay at zero honestly rather than being left null.
update market.exchange_cursor c
   set listings = 0
 where c.listings is null
   and not exists (
     select 1 from market.exchange_listing l where l.exch_code = c.exch_code
   );

notify pgrst, 'reload schema';
