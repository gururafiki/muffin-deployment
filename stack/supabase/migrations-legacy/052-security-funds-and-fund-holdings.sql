-- Two serving views the app had no way to ask for — IDEMPOTENT.
--
-- `fund_holding_current` is deliberately internal (a building block with no anon grant), so nothing
-- could answer either of the two obvious questions a person asks on a stock page:
--
--   "which funds hold this?"        -> market.security_funds
--   "what else is in that fund?"    -> market.fund_holdings
--
-- Both are the SAME join read from opposite ends, which is why they are one migration: they must
-- agree about weights and `as_of`, and two definitions written apart would eventually not.
--
-- WEIGHTS ARE AS FILED AND DO NOT SUM TO 100. EWT's own N-PORT sums to 110.38. Anything drawing a
-- proportion from these must renormalise; anything printing a single number must show `as_of`,
-- because N-PORT is filed ~60 days in arrears and a weight can be four months old.

drop view if exists market.security_funds;
create view market.security_funds as
select
  h.security_id,
  fi.value                          as fund_symbol,
  coalesce(tf.name, fs.name)        as fund_name,
  tf.kind                           as fund_kind,
  tf.represents_code                as represents_code,
  h.weight,
  h.as_of
from market.fund_holding_current h
join market.security_identifier fi
  on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
join market.security fs on fs.security_id = h.fund_id
left join market.tracked_fund tf on tf.symbol = fi.value
-- A fund holds itself in some filings; that is plumbing, not a holding.
where h.security_id <> h.fund_id;

comment on view market.security_funds is
  'Which tracked funds hold a given security, with the weight the fund REPORTED IN ITS FILING. Weights do not sum to 100 across a fund (EWT files 110.38) and are up to ~4 months old — always show as_of.';

drop view if exists market.fund_holdings;
create view market.fund_holdings as
select
  fi.value                          as fund_symbol,
  h.security_id,
  s.name,
  sym.symbol,
  s.country_iso2,
  s.security_type_code,
  s.currency_code,
  h.weight,
  h.market_value,
  h.as_of
from market.fund_holding_current h
join market.security_identifier fi
  on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
join market.security s on s.security_id = h.security_id
-- The DISPLAY symbol, which since migration 39 is the primary listing rather than the US OTC line:
-- 41% of non-US securities were labelled with a thin foreign-ordinary ticker they are not priced on.
left join market.security_symbol sym on sym.security_id = h.security_id
where h.security_id <> h.fund_id;

comment on view market.fund_holdings is
  'Everything a tracked fund holds, heaviest first when ordered by weight. The counterpart of security_funds — same join, read from the other end.';

grant select on market.security_funds, market.fund_holdings to anon, authenticated, service_role;

notify pgrst, 'reload schema';
