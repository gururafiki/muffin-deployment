-- MIGRATION 56 ADDED `provider_country_iso2` AND NOTHING WOULD EVER HAVE FILLED IT.
--
-- Caught by measuring after the deploy rather than by reading the diff: the column shipped, the
-- resource wrote it correctly, and production sat at **0 rows populated**. `security-profiles`
-- fills it, and `security-profiles` is driven by `pending_profile`, which asks for securities that
-- have NO sector. That backlog is drained — 0 rows — so the resource answers "every security has a
-- sector" and returns without fetching anything. The one population that needed the new column was
-- precisely the population the backlog had already finished with.
--
-- This is the same shape as `pending_industry` re-asking forever, inverted: a backlog defined by
-- one condition cannot serve a second condition that was added later. **A new column filled by an
-- existing resource needs its backlog widened in the same change, or it is inert.**
--
-- SCOPED TO THE SECURITIES THAT ACTUALLY NEED IT — 384, not 11,395. The whole point of the
-- operating country is to place a security a user can browse to, so the ones worth asking about
-- are those no country page can show:
--
--   84   have no country at all
--   300  are filed in a country with no market page, of which the offshore incorporations are the
--        real target: KY 119, BM 56, MH 10, VG. (LU 21, RU 17, IS 15, PT 13, RO 9, EG 7, HU 7 are
--        genuine countries that simply have no ETF, and the provider will agree with the filing —
--        asking is still correct, just uneventful.)
--
-- Re-queueing all 11,395 securities with a sector to collect a country would have been the obvious
-- reading of "fill the column", and it would have been wrong: THE BINDING CONSTRAINT IS REQUESTS
-- PER UNIT TIME, and spending eighteen runs of profile fetches on a field that changes nothing for
-- securities already on a country page would starve `security-statements`, which is 3,251 deep and
-- is the backlog a user actually notices.
--
-- `provider_country_missing_at` is the negative cache this needs, and it is not optional: without
-- it, a security whose profile carries no `hq_country` re-enters this backlog on every run for
-- ever. That failure has been rediscovered five times in this schema, which is why
-- `symbol_cache_classification` exists and why `negative-caches-are-classified.sql` fails CI on a
-- `%_missing_at` column nobody has classified. Symbol-keyed, because the profile is fetched BY
-- symbol — so a corrected symbol must clear it.

alter table market.security
  add column if not exists provider_country_missing_at timestamptz;

comment on column market.security.provider_country_missing_at is
  'The profile answered for this security and carried no resolvable hq_country. Without this the security re-enters pending_profile every run for ever.';

-- ── the clear list, which lives next to the columns so it cannot be forgotten ──
create or replace function market.clear_symbol_caches(p_security_id uuid)
returns void
language sql
security definer
set search_path = market, pg_temp
as $$
  update market.security set
    industry_missing_at         = null,
    profile_missing_at          = null,
    performance_missing_at      = null,
    fundamentals_missing_at     = null,
    statements_missing_at       = null,
    prices_missing_at           = null,
    provider_country_missing_at = null
  where security_id = p_security_id;
$$;

drop view if exists market.symbol_cache_classification;
create view market.symbol_cache_classification as
select * from (values
  ('industry_missing_at',         true,  'yfinance profile fetched by symbol'),
  ('profile_missing_at',          true,  'yfinance profile fetched by symbol'),
  ('performance_missing_at',      true,  'historical bars fetched by symbol'),
  ('fundamentals_missing_at',     true,  'metrics fetched by symbol'),
  ('statements_missing_at',       true,  'statements fetched by symbol'),
  ('prices_missing_at',           true,  'daily bars fetched by symbol'),
  ('provider_country_missing_at', true,  'yfinance profile fetched by symbol'),
  ('figi_missing_at',             false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',     false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',     false, 'the resolver''s own flag — clearing it here would loop')
) as t(column_name, symbol_keyed, reason);

grant select on market.symbol_cache_classification to service_role;

-- ── the backlog now has TWO reasons to want a profile ─────────────────────────
-- Dropped rather than replaced: this adds a `want` column, and `create or replace view` cannot
-- change a view's shape. Nothing else selects from it — it is read by the resource alone.
drop view if exists market.pending_profile;
create view market.pending_profile as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  s.name,
  coalesce(max(h.weight), 0) as best_weight,
  -- Which of the two reasons put this row here. The resource does not branch on it; it is here so
  -- an operator reading the backlog can see whether it is classifying or placing.
  case when st.security_id is null then 'sector' else 'country' end as want
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_taxonomy st
  on st.security_id = s.security_id and st.source_code = 'yfinance'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (
    -- 1. No sector: the original reason, unchanged.
    (st.security_id is null
     and (s.profile_missing_at is null or s.profile_missing_at < now() - interval '30 days'))
    or
    -- 2. No placeable country. Bounded to securities no country page can show, and closed off by
    --    its own negative cache so a profile without an `hq_country` is asked once, not for ever.
    (s.provider_country_iso2 is null
     and (s.country_iso2 is null
          or not exists (select 1 from market.countries c
                          where c.iso2 = s.country_iso2 and c.drillable))
     and (s.provider_country_missing_at is null
          or s.provider_country_missing_at < now() - interval '30 days'))
  )
group by s.security_id, coalesce(ps.symbol, t.value), s.name, st.security_id
order by best_weight desc;

grant select on market.pending_profile to service_role;

notify pgrst, 'reload schema';
