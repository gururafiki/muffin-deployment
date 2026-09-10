-- ONE venue catalog — IDEMPOTENT.
--
-- THE DEFECT. The same mapping (exchange code -> country -> yfinance suffix) existed twice: as
-- `LOCAL_EXCHANGES` in market-refresh/exchanges.ts and as the seed of `exchange_cursor`. Measured
-- 2026-08-12 they had DRIFTED — 54 venue rows in code against 38 in the database, with sixteen
-- present only in code:
--
--   C1/C2 -> .SS/.SZ (China)   CN -> .TO (Canada)    AU -> .AX (Australia)
--   BS -> .SA (Brazil)         DU/DH -> .AE (UAE)    CX -> .CL (Colombia)   and others
--
-- So `security-local-symbols` resolved symbols on venues that `exchange-listings` never swept.
-- Neither copy was wrong on its own; there were simply two of them, which is the condition that
-- produced the Taiwan bug (a hand-written table in code, spot-checked, silently missing a form).
--
-- This table is now the source of truth and the edge functions read it. The seed below was
-- EXTRACTED FROM THE CODE PROGRAMMATICALLY, not retyped — transcribing 54 rows by hand is the
-- same failure mode in a new place.

create table if not exists market.exchange (
  exch_code    text primary key,
  country_iso2 text references market.countries (iso2),
  suffix       text not null,
  preference   integer not null default 1,
  enabled      boolean not null default true,
  notes        text
);

comment on table market.exchange is
  'Venue catalog: OpenFIGI/Bloomberg exchange code -> country -> the suffix the price provider uses. Source of truth for both local-symbol resolution and the exchange sweep. Adding a venue is a row.';
comment on column market.exchange.preference is
  'Order within a country, lowest first. Korea lists KOSPI (1) before KOSDAQ (2) so a mid-cap on the secondary board still resolves, but the primary board wins when both answer.';
comment on column market.exchange.suffix is
  'Appended to the local ticker for the price provider. Empty string for US, which is why it is NOT NULL rather than nullable — an absent suffix and a US listing are different facts.';

insert into market.exchange (exch_code, country_iso2, suffix, preference) values
  ('US', 'US', '', 1),
  ('KS', 'KR', '.KS', 1),
  ('KQ', 'KR', '.KQ', 2),
  ('JT', 'JP', '.T', 1),
  ('JP', 'JP', '.T', 2),
  ('GY', 'DE', '.DE', 1),
  ('GR', 'DE', '.DE', 2),
  ('LN', 'GB', '.L', 1),
  ('FP', 'FR', '.PA', 1),
  ('SW', 'CH', '.SW', 1),
  ('SE', 'CH', '.SW', 2),
  ('NA', 'NL', '.AS', 1),
  ('IM', 'IT', '.MI', 1),
  ('SM', 'ES', '.MC', 1),
  ('SQ', 'ES', '.MC', 2),
  ('SS', 'SE', '.ST', 1),
  ('NO', 'NO', '.OL', 1),
  ('DC', 'DK', '.CO', 1),
  ('FH', 'FI', '.HE', 1),
  ('BB', 'BE', '.BR', 1),
  ('AV', 'AT', '.VI', 1),
  ('PL', 'PT', '.LS', 1),
  ('ID', 'IE', '.IR', 1),
  ('PW', 'PL', '.WA', 1),
  ('GA', 'GR', '.AT', 1),
  ('TI', 'TR', '.IS', 1),
  ('IT', 'IL', '.TA', 1),
  ('SJ', 'ZA', '.JO', 1),
  ('AB', 'SA', '.SR', 1),
  ('DU', 'AE', '.AE', 1),
  ('DH', 'AE', '.AE', 2),
  ('HK', 'HK', '.HK', 1),
  ('TT', 'TW', '.TW', 1),
  ('C1', 'CN', '.SS', 1),
  ('C2', 'CN', '.SZ', 2),
  ('IS', 'IN', '.NS', 1),
  ('IB', 'IN', '.BO', 2),
  ('SP', 'SG', '.SI', 1),
  ('TB', 'TH', '.BK', 1),
  ('IJ', 'ID', '.JK', 1),
  ('MK', 'MY', '.KL', 1),
  ('PM', 'PH', '.PS', 1),
  ('AT', 'AU', '.AX', 1),
  ('AU', 'AU', '.AX', 2),
  ('NZ', 'NZ', '.NZ', 1),
  ('CT', 'CA', '.TO', 1),
  ('CN', 'CA', '.TO', 2),
  ('BZ', 'BR', '.SA', 1),
  ('BS', 'BR', '.SA', 2),
  ('MM', 'MX', '.MX', 1),
  ('MF', 'MX', '.MX', 2),
  ('CI', 'CL', '.SN', 1),
  ('PE', 'PE', '.LM', 1),
  ('CX', 'CO', '.CL', 1)
on conflict (exch_code) do update set
  country_iso2 = excluded.country_iso2,
  suffix       = excluded.suffix,
  preference   = excluded.preference;

-- Keep the sweep in step with the catalog. `exchange_cursor` holds per-venue CURSOR STATE
-- (next_cursor, last_run_at, listings) and is written every run, so it stays — but its
-- `country_iso2`/`suffix` columns are now a synced copy rather than a second opinion.
--
-- They are not dropped, deliberately: migration 21 re-runs on every deploy and inserts into those
-- columns, so removing them would break the deploy after this one. Overwriting them from the
-- catalog costs one statement and leaves exactly one place to edit.
insert into market.exchange_cursor (exch_code, country_iso2, suffix)
select e.exch_code, e.country_iso2, e.suffix
from market.exchange e
where e.enabled
on conflict (exch_code) do update set
  country_iso2 = excluded.country_iso2,
  suffix       = excluded.suffix;

grant select on market.exchange to anon, authenticated, service_role;

notify pgrst, 'reload schema';
