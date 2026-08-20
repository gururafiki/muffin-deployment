-- Remember that a ticker lookup FAILED, so it is not retried forever — IDEMPOTENT.
--
-- WHY. `pending_ticker` selects "has an ISIN, has no ticker", which is the right question once.
-- But most securities in an emerging-markets or Japan fund have no US listing at all, and ticker
-- resolution asks OpenFIGI for the US line (`exchCode: 'US'`) — so they can never resolve.
-- Measured on the first keyed production run: 2,026 of 2,500 came back empty.
--
-- Without this column those 2,026 stay in the backlog and are re-sent to OpenFIGI on EVERY run,
-- four times a day, forever. That is a free API being hammered for an answer already known, and
-- it also starves the securities that COULD resolve — they sit behind a permanent queue of
-- failures. A negative result is a result and has to be recorded.
--
-- 30 days rather than never: a security can gain a US listing (an IPO, an ADR), so this is a
-- backoff, not a tombstone.

alter table market.security add column if not exists figi_missing_at timestamptz;
comment on column market.security.figi_missing_at is
  'When OpenFIGI last returned no US listing for this security. Excludes it from pending_ticker for 30 days so a permanent non-answer does not crowd out resolvable ones.';

create index if not exists security_figi_missing_idx on market.security (figi_missing_at);

create or replace view market.pending_ticker as
select
  s.security_id,
  isin.value as isin,
  s.name,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier isin
  on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where t.security_id is null
  and s.security_type_code = 'equity'
  and (s.figi_missing_at is null or s.figi_missing_at < now() - interval '30 days')
group by s.security_id, isin.value, s.name
order by best_weight desc;

grant select on market.pending_ticker to service_role;

notify pgrst, 'reload schema';
