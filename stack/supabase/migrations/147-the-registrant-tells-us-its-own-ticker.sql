-- THE REGISTRANT TELLS US ITS OWN TICKER, AND WE HAVE BEEN GUESSING.
--
-- `security-filing-history` fetches SEC's submissions document for every filer with a CIK, reads
-- the filing list and the SIC out of it, and throws the rest away. The rest includes the
-- registrant's OWN listing:
--
--     Apple      AAPL / Nasdaq        TSMC   TSM / NYSE
--     Alphabet   GOOGL / Nasdaq       UPS    UPS / NYSE
--
-- That matters because this pipeline resolves a US ticker through **OpenFIGI**, whose US lookup
-- returns the thin OTC foreign-ordinary line for most foreign companies — `TSMWF`, `ASMLF`,
-- `BUDFF`. CLAUDE.md records the cost: **621 of 1,015 rows** in the EPS backlog were OTC lines,
-- against a provider that allows **25 calls a DAY**, so ~26 days of budget went on learning one at
-- a time that an OTC line is an OTC line. SEC's answer is stated by the registrant rather than
-- inferred from a symbology database, and it arrives in a response we already make.
--
-- NOTHING IS RE-POINTED BY THIS MIGRATION, DELIBERATELY. It stores the fact and exposes a view of
-- where SEC and OpenFIGI disagree. Changing what the backlogs ASK for is a behaviour change with a
-- real blast radius across five resources, and the honest order is to measure the disagreement in
-- production first — this schema has been bitten more than once by a fix reasoned from a plausible
-- story rather than from a count.

-- ── The registrant's own identity ─────────────────────────────────────────────────────────────
--
-- A SEPARATE TABLE FROM `security_profile`, which already exists and holds a PROVIDER's view
-- (description, employees, beta from `equity/profile`). That table is keyed on `security_id` alone
-- with a single `source_code`, so two writers would silently overwrite each other on every run —
-- the same-fact-in-two-places drift this schema has already paid for once with the venue map.
-- These are REGISTRANT facts: what the company told the SEC, not what a data vendor believes.
create table if not exists market.filer_profile (
  security_id  uuid primary key references market.security (security_id) on delete cascade,
  entity_type  text,
  owner_org    text,
  ein          text,
  lei          text,
  -- `Large accelerated filer` and friends. A SIZE BAND THAT NEEDS NO CURRENCY, which is worth more
  -- here than it sounds: `security.market_cap` is denominated in each company's own currency, so
  -- ranking on it compares yen with dollars and the mega-cap canary is US-only for that reason.
  category     text,
  -- `0926` — the month and day the fiscal year ends. `security-segments` classifies a period by
  -- its DURATION (84-98 days is a quarter) because it has nothing better; this is the fact that
  -- explains a 52/53-week calendar, and it is what would let a fourth quarter be identified rather
  -- than inferred.
  fiscal_year_end text,
  state_of_incorporation text,
  website          text,
  investor_website text,
  phone            text,
  -- SEC'S OWN ANSWER to "what does this company trade as in the US". Positionally paired in the
  -- response: `tickers[0]` with `exchanges[0]`.
  us_ticker    text,
  us_exchange  text,
  hq_street    text,
  hq_city      text,
  -- SEC's field is `stateOrCountry` and is exactly that — `CA` for Apple is California, and for a
  -- foreign private issuer it is a country or nothing (TSMC's is null). NOT called `hq_country`,
  -- which would read as a country and be a state for every US filer. `security.country_iso2` and
  -- `provider_country_iso2` remain what anything joins on.
  hq_state_or_country text,
  hq_zip       text,
  source_code  text not null references market.data_source (code),
  as_of        timestamptz not null default now()
);

comment on table market.filer_profile is
  'What a registrant told the SEC about itself, from the submissions response `security-filing-history` already fetches. Separate from `security_profile`, which holds a PROVIDER''s view of the same company and is keyed so only one writer can own it.';
comment on column market.filer_profile.us_ticker is
  'The registrant''s own US ticker. Authoritative, unlike the OpenFIGI US lookup this pipeline otherwise relies on, which returns the thin OTC foreign-ordinary line (TSMWF, ASMLF, BUDFF) for most foreign companies.';
comment on column market.filer_profile.ein is
  'Employer Identification Number. SEC''s `000000000` placeholder is rejected at parse rather than stored — the same shape as `<cusip>000000000</cusip>`, which once collapsed four unrelated companies into one security.';

create index if not exists filer_profile_us_ticker_idx on market.filer_profile (us_ticker);

-- ── Name history ──────────────────────────────────────────────────────────────────────────────
--
-- Apple filed as APPLE COMPUTER INC until 2007. A holding from an older filing carries the name of
-- the day, so without this a pre-2007 record cannot be matched to today's security by name — and
-- name is the fallback whenever an identifier is missing, which N-PORT's 72% placeholder-CUSIP
-- rate makes common.
create table if not exists market.security_former_name (
  security_id uuid not null references market.security (security_id) on delete cascade,
  name        text not null,
  from_date   date,
  to_date     date,
  source_code text not null references market.data_source (code),
  primary key (security_id, name)
);

comment on table market.security_former_name is
  'Dated former names of a registrant, from SEC''s submissions response. Apple filed as APPLE COMPUTER INC until 2007; matching an older filing by name needs this.';

-- ── Where SEC and our own symbology disagree ──────────────────────────────────────────────────
--
-- The measurement that would justify re-pointing the backlogs, kept as a view so the number is
-- read from production rather than argued about. Deliberately does NOT change anything: it reports.
drop view if exists market.ticker_disagreement;
create view market.ticker_disagreement as
select
  s.security_id,
  s.name,
  s.country_iso2,
  f.us_ticker  as sec_ticker,
  f.us_exchange as sec_exchange,
  i.value      as openfigi_ticker,
  coalesce(max(h.weight), 0) as best_weight
from market.filer_profile f
join market.security s on s.security_id = f.security_id
left join market.security_identifier i
  on i.security_id = f.security_id and i.kind_code = 'ticker'
left join market.fund_holding_current h on h.security_id = f.security_id
where f.us_ticker is not null
  -- `is distinct from` rather than `<>`: a security with NO resolved ticker is precisely the
  -- interesting case, and `<>` would drop it because a comparison with NULL is NULL, not true.
  -- That is the falsy-NULL gate this schema has already been caught by, in its SQL form.
  and i.value is distinct from f.us_ticker
group by s.security_id, s.name, s.country_iso2, f.us_ticker, f.us_exchange, i.value
order by best_weight desc;

comment on view market.ticker_disagreement is
  'Securities where the registrant''s own US ticker differs from the one OpenFIGI resolved, weighted by fund holding. The measurement that decides whether the symbol-dependent backlogs should prefer SEC''s answer — read it before changing them.';

grant select on market.filer_profile, market.security_former_name, market.ticker_disagreement
  to anon, authenticated, service_role;
grant insert, update, delete on market.filer_profile, market.security_former_name to service_role;

alter table market.filer_profile      enable row level security;
alter table market.security_former_name enable row level security;
drop policy if exists filer_profile_read on market.filer_profile;
drop policy if exists security_former_name_read on market.security_former_name;
create policy filer_profile_read on market.filer_profile for select using (true);
create policy security_former_name_read on market.security_former_name for select using (true);

notify pgrst, 'reload schema';
