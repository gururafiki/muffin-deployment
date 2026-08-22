-- ALPHA_VANTAGE SERVES US LISTINGS, AND I FED IT `ASML.AS`.
--
-- Migration 122 bounded the EPS-history backlog by fund weight — correctly, because the provider
-- allows 25 calls a day — and bounded it by NOTHING ELSE. The first real run:
--
--     written: 0, securities: 0, noHistory: 1, failed: 2
--     error sending request ... historical_eps?symbol=ASML.AS
--
-- openbb-api was healthy throughout (`security-management` wrote 30 officers in the same minute).
-- The failure is the SYMBOL: alpha_vantage covers US listings, a foreign one hangs upstream until
-- the 20-second timeout, and a run of three spends a minute to write nothing. On a 25-call-a-day
-- budget that is not merely slow, it is the entire day's quota burnt on symbols that can never
-- answer.
--
-- ── TWO FIXES, AND THE SECOND IS THE ONE THIS SCHEMA KEEPS RELEARNING ───────────────────────────
--
-- The backlog now takes the US TICKER (`security_identifier` kind `ticker`, which is OpenFIGI's US
-- lookup) rather than `coalesce(provider_symbol, ticker)`. Migration 39 established that the
-- provider symbol is the RIGHT key for prices — it is the local line a quote comes from — and
-- `security-insider` established that the US ticker is the right one for anything asking a US-only
-- source. Fourth time the distinction has decided a resource: same company, two correct names,
-- chosen by who is being asked.
--
-- And the symbol must carry NO EXCHANGE SUFFIX. A dot is how every venue is spelled here —
-- `ASML.AS`, `SAP.DE`, `005930.KS` — while a US listing never has one, and an ADR like TSM has a
-- bare ticker precisely because it IS a US listing. Cheaper and more honest than inferring from the
-- company's country: Taiwan Semiconductor is Taiwanese and its ADR is servable.

drop view if exists market.pending_eps_history;
create view market.pending_eps_history as
select
  s.security_id,
  t.value as symbol,
  max(h.weight) as best_weight
from market.security s
join market.fund_holding_current h on h.security_id = s.security_id
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
where s.security_type_code = 'equity'
  -- A US LISTING HAS NO EXCHANGE SUFFIX. `ASML.AS` hangs upstream until the timeout and costs a
  -- call from a 25-a-day budget to learn nothing; `TSM` is a Taiwanese company whose ADR answers
  -- fine, which is why this tests the SYMBOL and not the country.
  and t.value not like '%.%'
  and (s.eps_history_fetched_at is null
       or s.eps_history_fetched_at < now() - interval '90 days')
group by s.security_id, t.value
-- THE TIGHTEST BOUND IN THE SCHEMA, and it has to be. 25 calls a DAY is ~9,000 a year; the top
-- holdings refreshed quarterly is ~2,000 of them. A looser threshold does not drain slower, it
-- exhausts the day's quota on the first cron run and fails every page-open after it.
having max(h.weight) >= 1.0
order by max(h.weight) desc;

comment on view market.pending_eps_history is
  'US-listed equities that are at least 1% of some tracked fund and whose EPS history is unread or a quarter old. Takes the US TICKER, not the provider symbol — alpha_vantage serves US listings, and a suffixed foreign symbol hangs upstream until the timeout, spending a call from a 25-a-day budget to learn nothing.';

grant select on market.pending_eps_history to service_role;

notify pgrst, 'reload schema';
