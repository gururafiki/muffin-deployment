-- Remember that a PROFILE lookup found nothing, so it is not retried forever — IDEMPOTENT.
--
-- Same defect the FIGI backlog had, and I reintroduced it: `pending_profile` asked "has a ticker,
-- has no yfinance sector", so a security yfinance cannot answer for stayed in the backlog and was
-- re-asked on every run. Measured 2026-08-10 during the drain: after the answerable securities
-- were classified, every subsequent run reported `classified: 0, unmapped: 0, remaining: 1000` —
-- the same thousand securities, forever, and no way to tell that from a provider outage.
--
-- Most of them are non-US local lines whose ticker yfinance does not carry. 30 days rather than
-- never: a listing can appear.

alter table market.security add column if not exists profile_missing_at timestamptz;
comment on column market.security.profile_missing_at is
  'When the profile provider last returned nothing for this security. Excludes it from pending_profile for 30 days so an unanswerable symbol does not crowd out answerable ones.';

create index if not exists security_profile_missing_idx on market.security (profile_missing_at);

create or replace view market.pending_profile as
select
  s.security_id,
  t.value as symbol,
  s.name,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_taxonomy st
  on st.security_id = s.security_id and st.source_code = 'yfinance'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where st.security_id is null
  and s.security_type_code = 'equity'
  and (s.profile_missing_at is null or s.profile_missing_at < now() - interval '30 days')
group by s.security_id, t.value, s.name
order by best_weight desc;

grant select on market.pending_profile to service_role;

notify pgrst, 'reload schema';
