-- alpha_vantage serves US listings, so the EPS backlog must ask only about companies that HAVE one.
--
-- WHY THIS EXISTS AS A TEST. The failure is invisible to every count in the system: the resource
-- asks, the provider answers `{}`, and the run reports success having learned nothing. Migration
-- 123 already believed it had fixed this by rejecting suffixed symbols — and OpenFIGI's US lookup
-- returns `ASMLF`, `BUDFF`, `TSMWF`, which carry no suffix and are not US listings either. 621 of
-- 1,015 backlog rows were in that state, each costing 4% of a 25-a-day quota to discover.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE, which is the point. Three rules could be written
-- here and two are wrong:
--
--   * "reject a dotted symbol"       — migration 123's rule. Keeps ASMLF. WRONG.
--   * "keep only primary US listings" — drops an ADR whose primary flag sits on the home venue.
--   * "keep anything with a US listing" — what shipped.
--
-- So the fixture contains an ADR whose PRIMARY listing is foreign (row 3). A test without it passes
-- under both of the last two rules and cannot tell them apart — the defect this file exists to
-- catch would survive a rewrite to the stricter one.

\set ON_ERROR_STOP on

begin;

-- Both venues already exist in the seeded catalogue; this is here so the fixture stands up on an
-- empty database too. `suffix` is not-null: a US listing has none, Amsterdam takes `.AS`.
insert into market.exchange (exch_code, country_iso2, suffix)
     values ('US', 'US', ''), ('NA', 'NL', '.AS')
on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  -- 1. An ordinary US company. Must be asked about.
  ('00000000-0000-0000-0000-000000124a01', 'T124 Domestic Inc',  'equity'),
  -- 2. The OTC foreign-ordinary line: bare ticker, foreign venue only. Must NOT be asked about.
  ('00000000-0000-0000-0000-000000124a02', 'T124 Foreign NV',    'equity'),
  -- 3. An ADR whose primary listing is the HOME venue. Must be asked about — this is the row that
  --    separates "has a US listing" from "is primarily US-listed".
  ('00000000-0000-0000-0000-000000124a03', 'T124 Adr Co',        'equity'),
  -- 4. A fund to hold them, so fund_holding_current has something to join.
  ('00000000-0000-0000-0000-000000124f01', 'T124 Fund',          'equity')
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000124a01', 'ticker', 'T124D'),
  ('00000000-0000-0000-0000-000000124a02', 'ticker', 'T124FF'),
  ('00000000-0000-0000-0000-000000124a03', 'ticker', 'T124A')
on conflict (kind_code, value) do nothing;

insert into market.listing (security_id, exch_code, symbol, is_primary) values
  ('00000000-0000-0000-0000-000000124a01', 'US', 'T124D',  true),
  -- Foreign venue only. No US line anywhere.
  ('00000000-0000-0000-0000-000000124a02', 'NA', 'T124F',  true),
  -- The ADR: primary on the home venue, and ALSO listed in the US.
  ('00000000-0000-0000-0000-000000124a03', 'NA', 'T124A',  true),
  ('00000000-0000-0000-0000-000000124a03', 'US', 'T124A',  false)
on conflict (security_id, exch_code) do nothing;

-- All three are large holdings, so weight cannot be what separates them.
insert into market.fund_holding
  (fund_id, security_id, as_of, weight, source_code) values
  ('00000000-0000-0000-0000-000000124f01', '00000000-0000-0000-0000-000000124a01', date '2026-06-30', 9.0, 'sec-nport'),
  ('00000000-0000-0000-0000-000000124f01', '00000000-0000-0000-0000-000000124a02', date '2026-06-30', 9.0, 'sec-nport'),
  ('00000000-0000-0000-0000-000000124f01', '00000000-0000-0000-0000-000000124a03', date '2026-06-30', 9.0, 'sec-nport')
on conflict (fund_id, security_id, as_of) do nothing;

do $$
declare
  has_domestic boolean;
  has_foreign  boolean;
  has_adr      boolean;
begin
  select exists (select 1 from market.pending_eps_history
                  where security_id = '00000000-0000-0000-0000-000000124a01') into has_domestic;
  select exists (select 1 from market.pending_eps_history
                  where security_id = '00000000-0000-0000-0000-000000124a02') into has_foreign;
  select exists (select 1 from market.pending_eps_history
                  where security_id = '00000000-0000-0000-0000-000000124a03') into has_adr;

  if not has_domestic then
    raise exception 'a US-listed equity is missing from pending_eps_history — the backlog now '
                    'excludes the population it exists to serve';
  end if;

  if has_foreign then
    raise exception 'the OTC foreign-ordinary line (bare ticker, foreign venue only) is still in '
                    'pending_eps_history — alpha_vantage answers it with an empty object, and each '
                    'such row costs 4%% of a 25-a-day quota to learn nothing';
  end if;

  if not has_adr then
    raise exception 'an ADR whose PRIMARY listing is foreign was dropped — the rule must be "has a '
                    'US listing", not "is primarily US-listed", or every ADR in the universe stops '
                    'being asked about';
  end if;

  raise notice 'ok  the EPS backlog asks about US-listed companies and ADRs, not OTC foreign lines';
end $$;

rollback;
