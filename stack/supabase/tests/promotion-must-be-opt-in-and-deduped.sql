-- Promotion must be OPT-IN, ordered by home market, and deduped by NAME — because the FIGI test
-- cannot see a cross-listing.
--
-- WHY THIS IS A TEST. 92,826 listings are untracked and every downstream backlog shares one
-- rate-limited provider budget, so promotion decides what the next month of that budget buys.
-- Three ways it goes wrong, all silent:
--   1. A deploy starts promoting on its own and starves the backlogs that serve securities people
--      are actually looking at.
--   2. It promotes by pool size, which puts Frankfurt first — measured 18.3% of whose untracked
--      listings name a company already held, against 0.5% for the US.
--   3. It promotes a cross-listing, minting a duplicate security that then consumes profile, price
--      and statement calls of its own. `untracked_listing` excludes by composite FIGI, and
--      composite_figi is per COUNTRY OF LISTING — so the listing is untracked while the company
--      is not.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('ZU','Homeland','ZU',false), ('ZX','Crosslistia','ZX',false)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix, preference) values
  ('ZHOME','ZU','.ZU',1), ('ZCROSS','ZX','.ZX',1)
on conflict (exch_code) do nothing;

-- A company we ALREADY hold.
insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000008401', 'ALREADY HELD PLC', 'equity')
on conflict (security_id) do nothing;

insert into market.exchange_listing (figi, composite_figi, exch_code, ticker, name, country_iso2, provider_symbol) values
  -- The SAME company, cross-listed. A different composite FIGI, so untracked_listing cannot see it.
  ('BBGZZZ0001','BBGZZZ0001','ZCROSS','AHP','ALREADY HELD PLC','ZX','AHP.ZX'),
  -- A genuinely new company on the cross-listing venue.
  ('BBGZZZ0002','BBGZZZ0002','ZCROSS','NEWX','AAA CROSS CO','ZX','NEWX.ZX'),
  -- A genuinely new company on the home venue.
  ('BBGZZZ0003','BBGZZZ0003','ZHOME','NEWH','ZED HOME CO','ZU','NEWH.ZU')
on conflict (figi) do nothing;

-- 1. DISABLED BY DEFAULT. Nothing is promotable until someone opts a venue in.
do $$
declare n integer;
begin
  select count(*) into n from market.pending_promotion where exch_code in ('ZHOME','ZCROSS');
  if n <> 0 then
    raise exception
      'a venue was promotable without being opted in (% rows) — with 92,826 untracked listings against a fixed provider budget, a deploy must not start spending it', n;
  end if;
end $$;

-- 2. OPTING IN SURFACES ONLY THE GENUINELY NEW ONES. The cross-listing of a company we hold is
--    excluded by NAME, which is the whole point — its FIGI says untracked.
update market.exchange set promotion_enabled = true where exch_code in ('ZHOME','ZCROSS');

do $$
declare names text[];
begin
  select array_agg(name order by name) into names
    from market.pending_promotion where exch_code in ('ZHOME','ZCROSS');
  if 'ALREADY HELD PLC' = any(names) then
    raise exception
      'a CROSS-LISTING of a company already held is queued for promotion — composite_figi is per country of listing, so the FIGI test cannot catch it and only the name can. Promoting it mints a duplicate that consumes profile, price and statement calls of its own';
  end if;
  if not ('AAA CROSS CO' = any(names) and 'ZED HOME CO' = any(names)) then
    raise exception 'genuinely new listings are missing from the backlog: %', names;
  end if;
end $$;

-- 3. HOME MARKETS COME FIRST. Ordering by pool size would put the cross-listing venue first,
--    because that is where the listings are. NOTE the fixture names sort AGAINST the tier
--    ('AAA CROSS CO' on the cross venue, 'ZED HOME CO' on the home one): with names that happened
--    to sort the same way as the tiers, `order by name` gave the right answer by coincidence and
--    this assertion could not fail.
update market.exchange set promotion_tier = 1 where exch_code = 'ZHOME';
update market.exchange set promotion_tier = 8 where exch_code = 'ZCROSS';

do $$
declare first_venue text;
begin
  select exch_code into first_venue
    from market.pending_promotion where exch_code in ('ZHOME','ZCROSS') limit 1;
  if first_venue is distinct from 'ZHOME' then
    raise exception
      'the backlog leads with % — a cross-listing venue is served before a home market, which spends a rate-limited budget on the listings whose data we already have', first_venue;
  end if;
end $$;

-- 4. A DISABLED VENUE IS EXCLUDED even when it is opted in — `enabled` is the existing kill switch
--    for a venue whose symbols do not resolve, and promotion must respect it.
update market.exchange set enabled = false where exch_code = 'ZHOME';
do $$
declare n integer;
begin
  select count(*) into n from market.pending_promotion where exch_code = 'ZHOME';
  if n <> 0 then raise exception 'a disabled venue is still promoting (% rows)', n; end if;
end $$;

rollback;
