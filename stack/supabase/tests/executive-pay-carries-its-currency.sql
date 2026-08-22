-- A pay figure must carry the currency it is denominated in, or be rendered unlabelled.
--
-- WHY THIS EXISTS AS A TEST. The failure is a plausible-looking wrong number, which no count, floor
-- or row check can see. SK hynix's chief executive is stored as 4,239,000,000 KRW (~$3m); with a
-- hardcoded `$` that is four billion dollars. The same defect already shipped once in this app as
-- Alibaba's CNY revenue printed as "$1.02T".
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. Four rows, and each isolates one branch:
--
--   1. reporting currency present, quote differs  -> the REPORTING currency wins (BHP/Shell shape)
--   2. no reporting currency, quote is not USD    -> the quote currency stands in
--   3. no reporting currency, quote USD, US       -> USD is real
--   4. no reporting currency, quote USD, NOT US   -> WITHHELD (the Alibaba/ADR shape)
--
-- Row 4 is the one that matters most and the one a negation would get wrong: written as
-- `currency_code <> 'USD'`, an unknown country yields NULL rather than true and the rule fails open
-- on exactly the security it was built for. Row 1 is the one that separates "reporting currency
-- first" from "quote currency first" — without it both orderings pass.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('US','T125 United States','US',false), ('AU','T125 Australia','AU',false)
on conflict (iso2) do nothing;
insert into market.currency (code, name) values
  ('USD','US Dollar'), ('AUD','Australian Dollar'), ('KRW','Korean Won'), ('JPY','Japanese Yen')
on conflict (code) do nothing;

insert into market.security
  (security_id, name, security_type_code, currency_code, reporting_currency,
   country_iso2, provider_country_iso2) values
  -- 1. Quotes AUD, reports USD. The reporting currency must win.
  ('00000000-0000-0000-0000-000000125a01','T125 Miner',     'equity','AUD','USD','AU',null),
  -- 2. No reporting currency; a non-USD quote can stand in.
  ('00000000-0000-0000-0000-000000125a02','T125 Korean',    'equity','KRW', null, null,'KR'),
  -- 3. A US company quoted in USD. USD is genuinely the answer.
  ('00000000-0000-0000-0000-000000125a03','T125 Domestic',  'equity','USD', null,'US', null),
  -- 4. Quoted USD, NOT American, no reporting currency. Nothing here says what the pay is in.
  ('00000000-0000-0000-0000-000000125a04','T125 Adr',       'equity','USD', null, null,'CN'),
  -- 5. Not yet priced anywhere, but the company states what it reports in. Without this row the
  --    first branch of the CASE is unreachable in the fixture and reordering it proves nothing.
  ('00000000-0000-0000-0000-000000125a05','T125 Unpriced',  'equity', null,'JPY', null,'JP')
on conflict (security_id) do nothing;

insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;
insert into market.security_officer (security_id, name, title, pay, fiscal_year, source_code) values
  ('00000000-0000-0000-0000-000000125a01','T125 A','Chief Executive Officer', 1000000, 2025,'yfinance'),
  ('00000000-0000-0000-0000-000000125a02','T125 B','Chief Executive Officer', 4239000000, 2025,'yfinance'),
  ('00000000-0000-0000-0000-000000125a03','T125 C','Chief Executive Officer', 2000000, 2025,'yfinance'),
  ('00000000-0000-0000-0000-000000125a04','T125 D','Chief Executive Officer', 3000000, 2025,'yfinance'),
  ('00000000-0000-0000-0000-000000125a05','T125 E','Chief Executive Officer', 5000000, 2025,'yfinance')
on conflict do nothing;

do $$
declare got text;
begin
  select pay_currency into got from market.security_leadership
   where security_id = '00000000-0000-0000-0000-000000125a01';
  if got is distinct from 'USD' then
    raise exception 'a company that QUOTES AUD and REPORTS USD is labelled % — the quote currency '
                    'is being preferred, so every BHP/Shell-shaped company mislabels its pay',
                    coalesce(got,'<null>');
  end if;

  select pay_currency into got from market.security_leadership
   where security_id = '00000000-0000-0000-0000-000000125a02';
  if got is distinct from 'KRW' then
    raise exception 'a KRW-quoted company with no reporting currency is labelled % — a 4.2bn won '
                    'package is about $3m and reads as four billion dollars unlabelled',
                    coalesce(got,'<null>');
  end if;

  select pay_currency into got from market.security_leadership
   where security_id = '00000000-0000-0000-0000-000000125a03';
  if got is distinct from 'USD' then
    raise exception 'a US company quoted in USD is labelled % — the rule has become so cautious it '
                    'withholds a currency that is genuinely known', coalesce(got,'<null>');
  end if;

  select pay_currency into got from market.security_leadership
   where security_id = '00000000-0000-0000-0000-000000125a04';
  if got is not null then
    raise exception 'a non-US company quoted in USD with no reporting currency is labelled % — '
                    'this is the Alibaba shape, and the rule has failed OPEN on the exact case it '
                    'exists for', got;
  end if;

  select pay_currency into got from market.security_leadership
   where security_id = '00000000-0000-0000-0000-000000125a05';
  if got is distinct from 'JPY' then
    raise exception 'a company with a stated reporting currency but no quote currency is labelled '
                    '% — the reporting currency must be consulted BEFORE the quote currency is '
                    'tested for null, or an unpriced security loses a label it has', coalesce(got,'<null>');
  end if;

  raise notice 'ok  pay carries its currency, and is withheld rather than guessed';
end $$;

rollback;
