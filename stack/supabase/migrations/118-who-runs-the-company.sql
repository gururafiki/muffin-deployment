-- WHO RUNS THE COMPANY — name, title, age and pay, from `equity/fundamental/management`.
--
-- Measured 2026-08-22: works GLOBALLY, which is unusual here. SAP.DE, 005930.KS and BHP.AX each
-- return ten officers, so this is not another US-only dataset — Samsung's Tae-Moon Roh and BHP's
-- Brandon Craig come back exactly as Tim Cook does.
--
-- ── THE SCOPE IS THE DESIGN, BECAUSE THIS ONE COMPETES ──────────────────────────────────────────
--
-- It does NOT batch (measured: two symbols return zero rows), so it costs one call per security on
-- YFINANCE — the provider `security-quarters`, `security-profile-detail`, `security-prices` and
-- `security-performance` are all already queued behind. Asking it of 12,350 equities would be
-- roughly fifty days of the shared limit spent on a list of names, and would slow every one of
-- those to do it.
--
-- So the population is bounded to securities that are a MEANINGFUL fund holding — at least 0.5% of
-- some tracked fund, which is ~2,300 holdings. That is the set whose pages actually get opened, and
-- it is the same reasoning that orders every other backlog here by weight: a percentage is free of
-- currency, market cap and country, and 34% of the universe has no cap at all.
--
-- The page is deliberately SMALL (15 a run) for the same reason. This resource is the least
-- urgent thing on that budget and must not out-compete a price series.

insert into market.data_source (code, name, priority) values ('yfinance-profile', 'yfinance company profile', 95)
on conflict (code) do nothing;

create table if not exists market.security_officer (
  security_id uuid not null references market.security (security_id) on delete cascade,
  -- The person IS the key. The response carries no id, and a company does not have two officers of
  -- the same name; re-fetching then updates a title rather than inserting a duplicate every run.
  name        text not null,
  title       text,
  pay         numeric,
  year_born   integer,
  age         integer,
  fiscal_year integer,
  source_code text not null references market.data_source (code),
  as_of       timestamptz not null default now(),
  primary key (security_id, name)
);

comment on table market.security_officer is
  'Named officers from `equity/fundamental/management` — global, unlike most of this schema. Keyed on the person''s name because the response carries no id and a company does not have two officers of the same name.';

grant select on market.security_officer to anon, authenticated, service_role;
grant insert, update, delete on market.security_officer to service_role;

alter table market.security_officer enable row level security;
drop policy if exists security_officer_read on market.security_officer;
create policy security_officer_read on market.security_officer for select using (true);

-- A CURSOR, not a negative cache: boards change, and a company with no officers listed this year
-- may have them next. Six months, because this is the slowest-moving fact in the schema.
alter table market.security add column if not exists management_fetched_at timestamptz;

comment on column market.security.management_fetched_at is
  'When the officer list was last read. A CURSOR at six months — a board is the slowest-moving fact here, and an absence is never permanent.';

drop view if exists market.pending_management;
create view market.pending_management as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  max(h.weight) as best_weight
from market.security s
join market.fund_holding_current h on h.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
where s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (s.management_fetched_at is null
       or s.management_fetched_at < now() - interval '180 days')
group by s.security_id, coalesce(ps.symbol, t.value)
-- BOUNDED TO MEANINGFUL HOLDINGS. `having` rather than `where`, because the threshold is about the
-- security's LARGEST weight across funds, not about any single holding row.
having max(h.weight) >= 0.5
order by max(h.weight) desc;

comment on view market.pending_management is
  'Equities that are at least 0.5% of some tracked fund and whose officer list is unread or six months old. Bounded deliberately: this costs one yfinance call per security and must not out-compete the price and statement backlogs on the same budget.';

grant select on market.pending_management to service_role;

-- The serving view: the people a reader recognises, not the whole list.
drop view if exists market.security_leadership;
create view market.security_leadership as
select
  o.security_id,
  o.name,
  o.title,
  o.pay,
  o.age,
  o.fiscal_year,
  -- THE CHIEF EXECUTIVE FIRST, then the rest by pay. A list ordered by pay alone puts whoever was
  -- granted the most equity that year at the top, which is not who runs the company.
  (o.title ilike '%chief executive%' or o.title ilike '%CEO%') as is_ceo
from market.security_officer o;

comment on view market.security_leadership is
  'Officers with a flag for the chief executive. Ordering by pay alone puts whoever was granted the most equity that year at the top, which is not who runs the company.';

grant select on market.security_leadership to anon, authenticated, service_role;

notify pgrst, 'reload schema';
