-- THE UNRESOLVED-NAME REPORT PAID FOR ITSELF ON ITS FIRST RUN.
--
-- Migration 56 deliberately shipped `country_alias` almost empty and made `security-profiles`
-- REPORT every provider country name it could not resolve, rather than guessing at yfinance's
-- vocabulary — because authoring reference data from memory is what silently dropped Taiwan once.
-- The first real run named six, and they are not alias spellings at all:
--
--   Macau  Monaco  Guernsey  Jersey  Isle of Man  Gibraltar
--
-- None of them is in `market.countries`. The table has 222 rows generated from the app's authored
-- constants — the world map's ISO list unioned with the modelled countries — and these six small
-- jurisdictions were in neither. So securities headquartered there resolved to nothing, were
-- negative-cached as having no usable country, and would have rendered "No country on file" on the
-- Other page for the next thirty days. A guessed alias table would never have found them; the
-- report did, in one run.
--
-- `market` IS LEFT NULL, and that is the honest answer rather than a gap. The column is an
-- INVESTMENT tier — MSCI's developed/emerging/frontier lens — and MSCI does not classify Jersey or
-- Monaco at all. Writing `frontier` to fill the column would state a classification nobody made.
--
-- `drillable` false: there is no single-country ETF for any of them, so there is no price series
-- and no country page. They will still appear under "Other" — but named, which is the difference
-- between "we could not place this" and "we do not know what this is".
--
-- THE FLAG IS DERIVED, NOT PASTED. It is a pure function of the ISO-2 code — the two regional
-- indicator symbols at U+1F1E6 + (letter - 'A') — and the rest of this table is stored exactly
-- that way (GB is U+1F1EC U+1F1E7). Computing it here means a seventh jurisdiction cannot arrive
-- with a mismatched flag.

insert into market.countries (iso2, name, flag, region_id, market, etf_symbol, drillable)
select
  c.iso2,
  c.name,
  chr(127462 + ascii(substr(c.iso2, 1, 1)) - 65) || chr(127462 + ascii(substr(c.iso2, 2, 1)) - 65),
  c.region_id,
  null,
  null,
  false
from (values
  -- A Chinese SAR, beside Hong Kong in the region the app already models for exactly this.
  ('MO', 'Macau',       'greater-china'),
  ('MC', 'Monaco',      'europe'),
  ('GG', 'Guernsey',    'europe'),
  ('JE', 'Jersey',      'europe'),
  ('IM', 'Isle of Man', 'europe'),
  ('GI', 'Gibraltar',   'europe')
) as c(iso2, name, region_id)
on conflict (iso2) do nothing;

-- ONE-SHOT: the reason those securities were marked has just stopped being true.
--
-- `provider_country_missing_at` records "the profile answered and gave no country we could use".
-- For these securities the profile DID give a country — we simply had no row to resolve it to.
-- Adding the rows changes the answer, so the mark has to go or they sit excluded for thirty days
-- waiting for a lookup that would now succeed. This is the same trap as the Taiwan bug: **a
-- negative cache can memorise your own missing reference data**, and a resolution fix must
-- invalidate what the old behaviour poisoned.
--
-- Guarded, because it must not run again: after this, a mark means what it says.
do $$
declare
  cleared bigint;
begin
  if exists (select 1 from market.one_shot where key = '60-clear-marks-for-newly-known-jurisdictions') then
    return;
  end if;

  update market.security
     set provider_country_missing_at = null
   where provider_country_missing_at is not null;

  get diagnostics cleared = row_count;

  insert into market.one_shot (key, reason) values
    ('60-clear-marks-for-newly-known-jurisdictions',
     format('Cleared %s provider_country_missing_at marks after adding Macau, Monaco, Guernsey, '
            || 'Jersey, Isle of Man and Gibraltar — the profile had answered with those names and '
            || 'market.countries had no row to resolve them to.', cleared));
end $$;

notify pgrst, 'reload schema';
