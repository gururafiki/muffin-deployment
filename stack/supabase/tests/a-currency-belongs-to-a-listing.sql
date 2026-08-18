-- Two listings of the same security may hold DIFFERENT currencies, and neither overwrites the other.
--
-- WHY THIS EXISTS. `security.currency_code` holds one value per security, so a security listed in
-- two places has one slot for two facts and whichever fetch ran last wins. That is the root cause
-- of the Jakarta defect: yfinance returned `currency: USD` for `BREN.JK`, and because the claim had
-- nowhere to live except a column shared by every listing, it overwrote the rupiah and made PT
-- Barito the largest company on earth at $442tn.
--
-- Camtek is the real case this models: `CAMT` on Nasdaq in USD, `CAMT.TA` on Tel Aviv in shekels.
-- Both true. The old shape cannot represent it; this one must.
--
-- The fallback is asserted too, because it is the majority of the universe: 15,159 bonds have NO
-- listing (12,379 listings against 27,629 securities) and their currency comes from the filing.
-- A normalization that deleted that fact would be worse than the flattening it replaced.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity'), ('bond', 'Bond')
  on conflict do nothing;
insert into market.currency (code) values ('USD'), ('ILS'), ('EUR') on conflict do nothing;
insert into market.data_source (code, name) values ('openfigi', 'OpenFIGI') on conflict do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values
  ('US', 'US', ''), ('IT', 'IL', '.TA')
on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code, currency_code) values
  -- Dual-listed: the case the old shape could not represent.
  ('00000000-0000-0000-0000-000000007501', 'T75 Dual listed', 'equity', 'USD'),
  -- A bond: no listing anywhere, currency from the filing.
  ('00000000-0000-0000-0000-000000007502', 'T75 Bond', 'bond', 'EUR')
on conflict (security_id) do nothing;

insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code, currency_code) values
  ('00000000-0000-0000-0000-000000007501', 'IT', 'T75DL', 'T75DL.TA', true,  'openfigi', 'ILS'),
  ('00000000-0000-0000-0000-000000007501', 'US', 'T75DL', 'T75DL',    false, 'openfigi', 'USD')
on conflict do nothing;

-- 1. THE TWO LISTINGS KEEP DIFFERENT CURRENCIES. This is the assertion the old shape fails.
do $$
declare n integer;
begin
  select count(distinct currency_code) into n
    from market.listing
   where security_id = '00000000-0000-0000-0000-000000007501';
  if n <> 2 then
    raise exception
      'a dual-listed security should hold 2 distinct listing currencies, holds % — one slot for two facts is what let a USD claim overwrite a rupiah', n;
  end if;
end $$;

-- 2. The effective currency is the PRIMARY listing's, not whichever was written last.
do $$
declare c text; src text;
begin
  select currency_code, source into c, src from market.security_currency
   where security_id = '00000000-0000-0000-0000-000000007501';
  if c is distinct from 'ILS' then
    raise exception 'the effective currency should be the PRIMARY listing''s (ILS), got %', coalesce(c,'<null>');
  end if;
  if src is distinct from 'listing' then
    raise exception 'source should say the listing supplied it, says %', coalesce(src,'<null>');
  end if;
end $$;

-- 3. A SECURITY WITH NO LISTING STILL HAS A CURRENCY. 15,159 bonds are in exactly this shape, so a
--    normalization that lost it would delete a fact for the majority of the universe.
do $$
declare c text; src text;
begin
  select currency_code, source into c, src from market.security_currency
   where security_id = '00000000-0000-0000-0000-000000007502';
  if c is distinct from 'EUR' then
    raise exception 'a bond with no listing must keep its filing currency (EUR), got %', coalesce(c,'<null>');
  end if;
  if src is distinct from 'security' then
    raise exception 'source should say the security supplied it, says %', coalesce(src,'<null>');
  end if;
end $$;

-- 4. WRITING ONE LISTING DOES NOT DISTURB THE OTHER — the collision made impossible, not merely
--    detected. This is what the ingest now does: it fetched by a symbol, so it writes to that
--    symbol's listing.
update market.listing
   set currency_code = 'USD'
 where security_id = '00000000-0000-0000-0000-000000007501'
   and provider_symbol = 'T75DL';

do $$
declare c text;
begin
  select currency_code into c from market.listing
   where security_id = '00000000-0000-0000-0000-000000007501' and provider_symbol = 'T75DL.TA';
  if c is distinct from 'ILS' then
    raise exception
      'writing the US listing changed the Tel Aviv one to % — the two facts are still sharing a slot', coalesce(c,'<null>');
  end if;
end $$;

rollback;
