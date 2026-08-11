-- Financial statements — IDEMPOTENT.
--
-- Verified available before building: `equity/fundamental/income`, `balance` and `cash` all return
-- real data from KEYLESS yfinance for non-US listings too. Measured 2026-08-11 — AAPL: income
-- 4 periods x 34 fields, balance 4 x 63, cash 4 x 46. Samsung (005930.KS): 4 x 48, 4 x 82, 4 x 58.
--
-- ONE JSONB PER PERIOD, not a column per line item. The two securities above differ by 19 income
-- fields and 19 balance fields, so a relational shape would be either the union of every line item
-- any filer reports (mostly null) or a migration whenever a provider adds one. The line items are
-- also not a fixed vocabulary — they are whatever the filing contains.
--
-- The trade-off, stated: aggregating across securities in SQL means `data->>'total_revenue'` and
-- no type safety on it. That is the right cost here, because the app's job is to SHOW a statement,
-- not to compute over 50 line items across 10,000 companies.

create table if not exists market.security_statement (
  security_id    uuid not null references market.security (security_id) on delete cascade,
  -- 'income' | 'balance' | 'cash'
  statement      text not null,
  period_ending  date not null,
  -- 'annual' | 'quarter'; the provider's own label, kept so a mixed set stays distinguishable.
  period_type    text,
  currency       text,
  data           jsonb not null,
  source_code    text not null references market.data_source (code),
  as_of          timestamptz not null default now(),
  primary key (security_id, statement, period_ending)
);
create index if not exists security_statement_sec_idx on market.security_statement (security_id, statement);

alter table market.security add column if not exists statements_missing_at timestamptz;

-- The backlog: has a symbol, has no statements yet. Ordered by fund weight, like every other one,
-- so the names a page actually renders are filled first.
create or replace view market.pending_statements as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_statement st on st.security_id = s.security_id
left join market.fund_holding_current h on h.security_id = s.security_id
where st.security_id is null
  and s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (s.statements_missing_at is null or s.statements_missing_at < now() - interval '30 days')
group by s.security_id, coalesce(ps.symbol, t.value)
order by best_weight desc;

alter table market.security_statement enable row level security;
do $$ begin
  create policy security_statement_public_read
    on market.security_statement for select to public using (true);
exception when duplicate_object then null; end $$;
grant select on market.security_statement to anon, authenticated, service_role;
grant select, insert, update, delete on market.security_statement to service_role;
grant select on market.pending_statements to service_role;

notify pgrst, 'reload schema';
