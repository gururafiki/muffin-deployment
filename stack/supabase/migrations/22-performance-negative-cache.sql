-- Remember that a security has NO price series — IDEMPOTENT.
--
-- Fourth instance of the same defect in this schema, so it is worth naming: a backlog view defined
-- as "wants X and does not have X" re-asks forever for the things that can never have X.
-- `pending_performance` selects securities with no fresh performance row, and yfinance simply does
-- not carry many local listings (`AMAK.SR`, `INRM.TA`, `NYKAA.NS` all return 204). Those symbols
-- were re-sent every run, crowding out the ones that would have resolved.
--
-- Compare `figi_missing_at`, `profile_missing_at`, `local_symbol_missing_at` — same shape, same
-- reason, same 30-day backoff so a listing that later appears is picked up.

alter table market.security add column if not exists performance_missing_at timestamptz;
comment on column market.security.performance_missing_at is
  'When the price provider last returned no series for this security. Excludes it from pending_performance for 30 days.';

create index if not exists security_perf_missing_idx on market.security (performance_missing_at);

drop view if exists market.pending_performance;
create view market.pending_performance as
select
  s.security_id,
  coalesce(t.value, ps.symbol) as symbol,
  coalesce(ps.symbol, t.value) as fetch_symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.performance p
  on p.scope = 'instrument' and p.scope_id = coalesce(t.value, ps.symbol) and p.stale_after > now()
left join market.fund_holding_current h
  on h.security_id = s.security_id
where p.scope_id is null
  and s.security_type_code = 'equity'
  and coalesce(t.value, ps.symbol) is not null
  and (s.performance_missing_at is null or s.performance_missing_at < now() - interval '30 days')
group by s.security_id, coalesce(t.value, ps.symbol), coalesce(ps.symbol, t.value)
order by best_weight desc;

grant select on market.pending_performance to service_role;

notify pgrst, 'reload schema';
