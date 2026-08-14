-- A country the app offers a page for must have a venue the sweep can enumerate.
--
-- WHY THIS EXISTS. The gap was invisible from either side on its own. `market.countries` said 45
-- countries were drillable; `market.exchange` covered 42; and nothing compared the two. The
-- symptom was three countries whose securities all had NO SYMBOL — Kuwait 40, Qatar 35, Vietnam
-- 57 — which reads as a provider limitation rather than as "we never swept their exchange". That
-- is the Taiwan signature exactly: securities present, symbols absent, no error anywhere.
--
-- Asserted as a JOIN rather than a count, so the failure names the country instead of saying 42
-- against 45. `market-verify` check 8 catches the same class in production (a country with
-- securities and zero provider symbols); this catches it before a deploy, and catches the case
-- production cannot see — a drillable country with no securities AT ALL, which is what Argentina
-- was and which no per-security check can distinguish from an empty market.

\set ON_ERROR_STOP on

begin;

do $$
declare
  missing text;
begin
  select string_agg(format('%s (%s)', c.name, c.iso2), ', ' order by c.name)
    into missing
  from market.countries c
  where c.drillable
    and not exists (
      select 1 from market.exchange e
       where e.country_iso2 = c.iso2 and e.enabled
    );

  if missing is not null then
    raise exception 'drillable countries with no venue in market.exchange: %. '
                    'Their securities can never resolve a symbol, which looks like a provider '
                    'limitation and is not. Derive the exchCode from OpenFIGI /v3/mapping on an '
                    'ISIN you already hold, and the SUFFIX from Yahoo search on the ticker it '
                    'returns — the two differ (Doha is QD and .QA).', missing;
  end if;
  raise notice 'ok  every drillable country has a venue the sweep can enumerate';
end $$;

rollback;
