-- THE UNIVERSE SAMPLE READS `insider_trade`'s FRESHNESS FROM AN INDEX. Migration 20261108170000.
--
-- WHY THIS EXISTS. `sample_universe` reads `max(as_of)` of every timestamped `market` table each hour.
-- On `insider_trade` (5.52 M rows after the 2026-11-07 insider history) that was a 33.4 s sequential
-- scan, two thirds of the sample. Runs were cancelled at their 60 s bound, and "The scheduler has
-- stopped firing" fired on a healthy scheduler. A `max()` can only use a btree that LEADS on the
-- column, and on CI's empty tables no plan or timing can tell, so this reads the catalogue.

\set ON_ERROR_STOP on

do $$
begin
  if not exists (
    select 1
      from pg_index i
      join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
      join pg_class am on am.oid = i.indexrelid
      join pg_am m on m.oid = am.relam
     where i.indrelid = 'market.insider_trade'::regclass
       and a.attname = 'as_of'
       and m.amname = 'btree'
       and i.indpred is null) then
    raise exception 'no btree index on market.insider_trade leads on as_of: sample_universe''s '
                    'max(as_of) is then a sequential scan of the whole table (33.4 s at 5.5 M rows), '
                    'and the hourly sample is cancelled at its bound';
  end if;
  raise notice 'ok  insider_trade''s freshness is read from an index leading on as_of';
end $$;
