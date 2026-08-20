-- 15,159 BONDS — THE LARGEST SLICE OF THE UNIVERSE — CARRIED NO COUPON AND NO MATURITY,
-- AND THE DATA WAS IN A FILE WE ALREADY DOWNLOAD AND PARSE.
--
-- `market.security` is majority bonds (15,159 against 12,350 equities) because AGG, LQD, HYG, TIP
-- and EMB were added as tracked funds. They arrived with a name, an ISIN, an issuer and a country,
-- and then nothing: no coupon, no maturity, no default status. A bond without those is barely a
-- record of anything — you cannot sort by yield, filter by duration, or say whether a holding
-- matures next year or in 2049.
--
-- Every N-PORT debt holding carries a `<debtSec>` block, and `parseHoldings` read the fields
-- around it and skipped it. Measured 2026-08-18 against AGG's actual filing:
--
--   8,867 of 8,870 holdings carry <debtSec>          (100% of the debt ones)
--   <maturityDt> inside <debtSec>: 8,867, OUTSIDE: 0
--   couponKind: Fixed 8,819 · Variable 30 · Floating 13 · None 5
--   annualizedRt: range 0.0 to 11.5
--   isDefault: N on all 8,867
--
-- This is the SIXTH time the answer was already in a response we were fetching — market cap twice,
-- the operating country, the currency, dividends, and now the whole debt profile.
--
-- TWO VALUES THAT LOOK MISSING AND ARE NOT, which is why they were measured before being modelled:
--
--   * `couponKind` is literally the string "None" on 5 holdings. That is a reported kind, not an
--     absence, so it is a lookup ROW like every other categorical here — collapsing it to null
--     would lose the difference between "pays no coupon" and "not stated".
--   * `annualizedRt` of 0.0 is a REAL ZERO-COUPON BOND. A truthiness test would drop every one of
--     them. Note this is the exact opposite of the dividend case in the same week, where a 0 means
--     "no dividend on this bar" and must NOT become a row. Same-looking value, opposite meaning.
--
-- WHY ON `security` AND NOT ON `fund_holding`. A bond's coupon and maturity are properties of the
-- INSTRUMENT, not of anyone's position in it: two funds holding the same bond report the same
-- maturity. Putting them on the holding would store the same fact once per fund and invite them to
-- disagree. `debt_terms_as_of` records which filing they came from, because a floating-rate note's
-- `annualizedRt` is a snapshot at the filing date rather than a fixed property.

-- The coupon kinds are LEARNED from filings, exactly like currency, asset_category and
-- issuer_category — the ingest upserts what it sees. Seeding a guessed vocabulary here is how the
-- venue map drifted to 54 rows against 38.
create table if not exists market.coupon_kind (
  code text primary key,
  name text
);

comment on table market.coupon_kind is
  'N-PORT couponKind values, LEARNED from filings rather than seeded. Observed 2026-08-18: Fixed, Variable, Floating, None — where "None" is a reported kind (a bond that pays no coupon), not a missing value.';

alter table market.security
  add column if not exists maturity_date     date,
  add column if not exists coupon_rate       numeric,
  add column if not exists coupon_kind_code  text references market.coupon_kind (code),
  add column if not exists in_default        boolean,
  add column if not exists debt_terms_as_of  timestamptz;

comment on column market.security.coupon_rate is
  'Annualised coupon percent from N-PORT annualizedRt. 0.0 is a REAL zero-coupon bond, not a missing value — do not test it for truthiness.';
comment on column market.security.debt_terms_as_of is
  'Which filing these terms came from. A floating-rate note''s annualizedRt is a snapshot at the filing date, not a fixed property of the instrument.';

-- Sorting and filtering bonds is the whole point, and the universe is 15,159 of them.
create index if not exists security_maturity_idx
  on market.security (maturity_date)
  where maturity_date is not null;

grant select on market.coupon_kind to anon, authenticated;
grant select, insert, update, delete on market.coupon_kind to service_role;

-- RLS by policy, not by grants alone — the rule for every market table since 09-market-rls.sql.
alter table market.coupon_kind enable row level security;
do $$ begin
  create policy coupon_kind_public_read on market.coupon_kind for select using (true);
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';

-- ── The write path ────────────────────────────────────────────────────────────────────────────
--
-- One statement per chunk rather than one round trip per bond. AGG alone is 8,867 debt holdings,
-- and the ingest already runs against a 60-second worker; a per-security update loop would not
-- finish, and `update … from jsonb_to_recordset` expresses "different values per row" in a single
-- statement, which a bulk `update … where id in (…)` cannot.
--
-- Deliberately an UPDATE, not an upsert: every security here has just been resolved or created by
-- `resolveSecurities`, so a row that is missing is a bug to surface rather than a row to invent —
-- and an upsert would need `name` and `security_type_code` in its insert path, which would let a
-- debt-terms write silently rewrite a security's TYPE. Migration 49 exists because that type was
-- wrong for 15,205 securities once already.
create or replace function market.set_debt_terms(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = market, pg_temp
as $$
declare
  n integer;
begin
  update market.security s
     set maturity_date    = r.maturity_date,
         coupon_rate      = r.coupon_rate,
         coupon_kind_code = r.coupon_kind_code,
         in_default       = r.in_default,
         debt_terms_as_of = r.as_of
    from jsonb_to_recordset(p_rows) as r(
           security_id uuid,
           maturity_date date,
           coupon_rate numeric,
           coupon_kind_code text,
           in_default boolean,
           as_of timestamptz
         )
   where s.security_id = r.security_id
     -- NEVER let an older filing overwrite a newer one. Funds are ingested in whatever order the
     -- backlog offers, and two funds holding the same bond file at different quarter-ends, so
     -- without this the stored terms would flap depending on which fund ran last.
     and (s.debt_terms_as_of is null or r.as_of >= s.debt_terms_as_of);

  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function market.set_debt_terms(jsonb) to service_role;
