-- The statements view must expose the EFFECTIVE country, or the currency gate fails open.
--
-- WHY THIS EXISTS. Migration 65 appended `country_iso2` so a caller could withhold the currency
-- label for a non-US company quoted in USD — an ADR does not report in the currency it trades in,
-- and Alibaba's CNY revenue was rendering as $1.02 TRILLION. It took the column from `s.country_iso2`,
-- the FILED country, and BABA has none: it was promoted from the exchange directory, so there is no
-- filing and its only country is `provider_country_iso2`.
--
-- A NULL country is falsy, so the caller's `country !== 'US'` test declines to fire and the label
-- goes back on — on the exact security the change exists for. **A guard that fails open on its own
-- headline case is worse than no guard, because it is now believed.** Measured in production before
-- this was written: 21 securities have statements, are quoted in USD and have no filed country.

\set ON_ERROR_STOP on

begin;

insert into market.data_source (code, name) values ('yfinance','yfinance') on conflict (code) do nothing;
-- Currencies are LEARNED by the ingest at runtime, so no migration seeds them and a test that
-- references one has to create it — the same rule `securities-are-typed-from-the-filing.sql`
-- follows for `data_source` and `asset_category`.
insert into market.currency (code) values ('USD') on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, currency_code,
                             country_iso2, provider_country_iso2) values
  -- The BABA shape: promoted from the directory, so NO filed country, operating country only.
  ('00000000-0000-0000-0000-0000000066a1', 'T66 Promoted ADR', 'equity', 'USD', null, 'CN'),
  -- Ingested from a filing, foreign, quoted USD — the case 65 already handled.
  ('00000000-0000-0000-0000-0000000066a2', 'T66 Filed ADR',    'equity', 'USD', 'BR', null),
  -- A US company: the label is correct and must survive.
  ('00000000-0000-0000-0000-0000000066a3', 'T66 US company',   'equity', 'USD', 'US', null)
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-0000000066a1', 'ticker', 'T66A'),
  ('00000000-0000-0000-0000-0000000066a2', 'ticker', 'T66B'),
  ('00000000-0000-0000-0000-0000000066a3', 'ticker', 'T66C')
on conflict (kind_code, value) do nothing;

insert into market.security_statement (security_id, statement, period_ending, data, source_code, as_of) values
  ('00000000-0000-0000-0000-0000000066a1', 'income', '2026-06-30', '{"total_revenue": 1}', 'yfinance', now()),
  ('00000000-0000-0000-0000-0000000066a2', 'income', '2026-06-30', '{"total_revenue": 1}', 'yfinance', now()),
  ('00000000-0000-0000-0000-0000000066a3', 'income', '2026-06-30', '{"total_revenue": 1}', 'yfinance', now())
on conflict (security_id, statement, period_ending) do nothing;

do $$
declare
  bad text;
begin
  -- The caller's rule, expressed here so the test fails for the reason the UI would.
  select string_agg(format('%s: country=%s -> label %s, expected %s',
                           s.name, coalesce(v.country_iso2,'<null>'),
                           case when v.currency_code = 'USD'
                                 and coalesce(v.country_iso2,'') <> 'US'
                                 and v.country_iso2 is not null then 'withheld' else 'USD' end,
                           e.want), '; ')
    into bad
  from market.security_statement_current v
  join market.security s on s.security_id = v.security_id
  join (values
    ('00000000-0000-0000-0000-0000000066a1'::uuid, 'withheld'),
    ('00000000-0000-0000-0000-0000000066a2'::uuid, 'withheld'),
    ('00000000-0000-0000-0000-0000000066a3'::uuid, 'USD')
  ) e(security_id, want) on e.security_id = v.security_id
  where (case when v.currency_code = 'USD'
               and coalesce(v.country_iso2,'') <> 'US'
               and v.country_iso2 is not null then 'withheld' else 'USD' end)
        is distinct from e.want;

  if bad is not null then
    raise exception 'the currency gate does not behave as intended: %', bad;
  end if;
  raise notice 'ok  a promoted ADR withholds the label, a filed ADR withholds it, a US company keeps it';
end $$;

rollback;
