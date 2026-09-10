-- SPLITS AND DIVIDENDS, RECORDED RATHER THAN INFERRED FROM A PRICE JUMP.
--
-- Until now this pipeline has had no corporate-action data at all. `firstComparableIndex` INFERS a
-- discontinuity — it refuses to report a return whose anchor predates a >5x single-bar move — which
-- stops a split fabricating a +900% and does nothing else. The stored closes stay unadjusted, the
-- pre-split history is silently excluded rather than corrected, and the same rule fires on a
-- REDENOMINATION (Tel Aviv moving quotes from shekels to agorot, 2026-05-18), which is not a
-- corporate action at all. Inference cannot tell those apart. A recorded split can.
--
-- THE SOURCE IS TIINGO, and it was ruled out on this project once already for a reason that is no
-- longer true. `todos.md` said "Tiingo free is limited to the DOW 30"; measured 2026-08-15 with the
-- key that has been sitting in GitHub secrets since 08-10, that is wrong. Its daily EOD carries
-- `divCash`, `splitFactor` and `adjClose` PER BAR, and it answered for every US-listed name tried —
-- ROST, STX, TPR, ISRG, SNDK — plus ADRs (BABA, VALE). A 28-symbol sample of OUR OWN tickers came
-- back **26 covered (93%)**, including thin OTC foreign-ordinary lines like ASPHF and BSFFF.
--
-- WHAT IT DOES NOT COVER: local foreign listings. `7203.T`, `SAP.DE`, `005930.KS` and `NESN.SW` all
-- 404. So this reaches the ~6,645 securities with a US ticker, not the 12,350 equities — and that
-- is the honest scope. A Japanese split will still be invisible.
--
-- ONE TABLE, TWO KINDS, because they arrive in the same bar and differ only in what they mean.
-- `kind` is a FK to a lookup rather than a CHECK or an enum, following the rule the rest of this
-- schema uses: a new kind (a spin-off, a rights issue) is a row, not a migration.

create table if not exists market.corporate_action_kind (
  code text primary key,
  name text not null
);

insert into market.corporate_action_kind (code, name) values
  ('split',    'Stock split'),
  ('dividend', 'Cash dividend')
on conflict (code) do update set name = excluded.name;

create table if not exists market.security_corporate_action (
  security_id uuid    not null references market.security(security_id) on delete cascade,
  ex_date     date    not null,
  kind        text    not null references market.corporate_action_kind(code),
  -- A split's RATIO (2.0 = two-for-one, 0.1 = a one-for-ten reverse) or a dividend's CASH per
  -- share, in the security's own currency. One column because a row is one or the other and
  -- `kind` says which; two nullable columns would permit a row that is neither.
  value       numeric not null,
  source_code text    not null references market.data_source(code),
  as_of       timestamptz not null default now(),
  primary key (security_id, ex_date, kind)
);

comment on table market.security_corporate_action is
  'Splits and cash dividends with their ex-date, from Tiingo daily EOD (US-listed only — local foreign listings 404). Recorded rather than inferred: firstComparableIndex can only see that a price jumped, not whether it was a split, a redenomination or a real move.';

create index if not exists security_corporate_action_date_idx
  on market.security_corporate_action (ex_date desc);

alter table market.security_corporate_action enable row level security;
alter table market.corporate_action_kind      enable row level security;
drop policy if exists corporate_action_read on market.security_corporate_action;
create policy corporate_action_read on market.security_corporate_action for select using (true);
drop policy if exists corporate_action_kind_read on market.corporate_action_kind;
create policy corporate_action_kind_read on market.corporate_action_kind for select using (true);

grant select on market.security_corporate_action, market.corporate_action_kind
  to anon, authenticated, service_role;
-- Both tables, not just the data one. `every-table-is-reachable.sql` caught the omission on the
-- first run — the same shape as migration 42, which created a table, passed every check, and was
-- unreachable in production with `permission denied for table security_price`. A lookup table is
-- still a table someone will add a row to.
grant insert, update, delete on market.security_corporate_action, market.corporate_action_kind
  to service_role;

insert into market.data_source (code, name) values ('tiingo', 'Tiingo')
on conflict (code) do nothing;

-- The negative cache. Tiingo does not carry local foreign listings, and asking again every run for
-- `7203.T` is the failure this schema has now hit six times.
alter table market.security
  add column if not exists corporate_actions_missing_at timestamptz;

comment on column market.security.corporate_actions_missing_at is
  'Tiingo answered about this security and had nothing, or does not carry it. Symbol-keyed: the request is made BY the US ticker, so a corrected symbol invalidates it.';

-- Symbol-keyed, so `clear_symbol_caches` must null it. `negative-caches-are-classified.sql` fails
-- CI on a `%_missing_at` column nobody has classified, which is why this is not optional.
create or replace function market.clear_symbol_caches(p_security_id uuid)
returns void
language sql
security definer
set search_path = market, pg_temp
as $$
  update market.security set
    industry_missing_at          = null,
    profile_missing_at           = null,
    performance_missing_at       = null,
    fundamentals_missing_at      = null,
    statements_missing_at        = null,
    prices_missing_at            = null,
    provider_country_missing_at  = null,
    corporate_actions_missing_at = null
  where security_id = p_security_id;
$$;

drop view if exists market.symbol_cache_classification;
create view market.symbol_cache_classification as
select * from (values
  ('industry_missing_at',          true,  'yfinance profile fetched by symbol'),
  ('profile_missing_at',           true,  'yfinance profile fetched by symbol'),
  ('performance_missing_at',       true,  'historical bars fetched by symbol'),
  ('fundamentals_missing_at',      true,  'metrics fetched by symbol'),
  ('statements_missing_at',        true,  'statements fetched by symbol'),
  ('prices_missing_at',            true,  'daily bars fetched by symbol'),
  ('provider_country_missing_at',  true,  'yfinance profile fetched by symbol'),
  ('corporate_actions_missing_at', true,  'Tiingo EOD fetched by the US ticker'),
  ('figi_missing_at',              false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',      false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop')
) as t(column_name, symbol_keyed, reason);

grant select on market.symbol_cache_classification to service_role;

-- ── the backlog ──────────────────────────────────────────────────────────────
-- ORDERED BY FUND WEIGHT, like every other backlog here, and that ordering is doing real work:
-- Tiingo's free tier caps UNIQUE SYMBOLS, not requests, so the securities that matter must be
-- covered first rather than whatever the table returns. A `security_id` tiebreak makes the pages a
-- partition rather than four samples — see the note on `pending_ticker`.
drop view if exists market.pending_corporate_actions;
create view market.pending_corporate_actions as
select
  s.security_id,
  t.value as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and (s.corporate_actions_missing_at is null
       or s.corporate_actions_missing_at < now() - interval '30 days')
  -- NULL-checks the FIRST left-joined table, which is the shape every draining backlog here has.
  -- `pending_industry` reached for a SECOND table through an unrestricted join and re-asked the
  -- same 300 securities for weeks.
  and not exists (
    select 1 from market.security_corporate_action a
     where a.security_id = s.security_id
       and a.as_of > now() - interval '30 days'
  )
group by s.security_id, t.value
order by best_weight desc;

grant select on market.pending_corporate_actions to service_role;

notify pgrst, 'reload schema';
