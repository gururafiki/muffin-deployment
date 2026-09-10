-- The fundamentals backlog — IDEMPOTENT.
--
-- Viable only because the source turned out to be keyless yfinance rather than a rate-limited
-- provider: 25 calls a day would have been ~400 days for 10,060 securities, so fundamentals were
-- designed as an on-demand-only feature. They are not.
--
-- `fundamentals_missing_at` is included UP FRONT. Five backlogs have now needed it after the fact
-- (figi, profile, local symbol, performance, industry), each discovered by a drain loop spinning
-- on the same rows — the pattern is established enough to stop rediscovering.

alter table market.security add column if not exists fundamentals_missing_at timestamptz;

create or replace view market.pending_fundamentals as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_fundamentals f on f.security_id = s.security_id
left join market.fund_holding_current h on h.security_id = s.security_id
where f.security_id is null
  and s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (s.fundamentals_missing_at is null or s.fundamentals_missing_at < now() - interval '30 days')
group by s.security_id, coalesce(ps.symbol, t.value)
order by best_weight desc;

grant select on market.pending_fundamentals to service_role;

notify pgrst, 'reload schema';
