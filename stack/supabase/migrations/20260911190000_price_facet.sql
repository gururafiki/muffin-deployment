-- The price facet, so a symbol the provider will never serve stops costing a request a day.
--
-- WHY THIS IS A MIGRATION AND NOT A ROW THE PIPELINE WRITES. `ingest.facet` is a control table and
-- migration 207 revoked DML on it from `ingest_rw` deliberately: `mark_absent` is SECURITY DEFINER
-- and `execute`s `retract_sql`, so a worker able to write that column could run any statement as a
-- superuser. A guard the guarded party can walk around is documentation.
--
-- WHAT IT BUYS. `openbb_yfinance` calls `yf.download(..., threads=False)`, so the vendor is asked
-- ONCE PER SYMBOL whatever we batch — a symbol it will never serve therefore costs a real request
-- every single day. Measured on the current universe: ~425 equities have no currency and a similar
-- population answers nothing at all, which at one request each is ~155,000 wasted vendor requests a
-- year, spent re-learning an answer we already had.

-- THE BUDGET FIRST: `facet.provider_code` references `provider_budget`, so the other order fails
-- with `violates foreign key constraint "facet_provider_code_fkey"`. Found by applying this to the
-- real database inside a rolled-back transaction rather than to an empty one, where it would have
-- failed just as loudly but a deploy later.

-- The vendor's own pacing, so a cooldown survives a run. `rate_per_sec` is denominated in SYMBOLS,
-- never in calls: joining symbols collapses OUR call count and never theirs.
insert into ingest.provider_budget (
  provider_code, rate_per_sec, burst, daily_quota, cooldown, control_subject, enabled, note
) values (
  'yfinance', 1.0, 1, null, interval '15 minutes', 'AAPL', true,
  'Keyless and undocumented. One request per SYMBOL — a batched call is not a batched request.'
)
on conflict (provider_code) do update set
  rate_per_sec = excluded.rate_per_sec, cooldown = excluded.cooldown,
  control_subject = excluded.control_subject, enabled = excluded.enabled, note = excluded.note;

insert into ingest.facet (
  facet, family, asset, provider_code, key_kind, grain,
  ttl, absent_ttl, backoff, batch_size, page_size, control_subject,
  population_sql, retract_sql, old_resource, old_missing_column, enabled, note
) values (
  'prices', 'prices', 'raw_price_bars', 'yfinance', 'symbol', 'security',
  -- A daily bar is stale after a day. `absent_ttl` is THIRTY DAYS AND NOT NEVER: a security can
  -- gain a listing, and a symbol repair must be allowed to prove the provider wrong.
  interval '1 day', interval '30 days', interval '1 hour',
  20, 500,
  -- The control that proves the provider is healthy before anything is called dead. Without one,
  -- `mark_absent` refuses — which is the point.
  'AAPL',
  $pop$
    select s.security_id::text                         as subject,
           s.security_id                               as security_id,
           coalesce(max(h.weight), 0)::numeric         as priority,
           1::numeric                                  as entity_rank
      from market.security s
      join market.security_symbol sym on sym.security_id = s.security_id
      left join market.security_provider_symbol ps
             on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
      left join market.fund_holding_current h on h.security_id = s.security_id
     where s.security_type_code = 'equity'
       and coalesce(ps.symbol, sym.symbol) is not null
     group by s.security_id
  $pop$,
  -- THE BARS ARE NOT RETRACTED, AND THAT IS THE WHOLE DECISION HERE.
  --
  -- A symbol-keyed facet must declare a retraction (`symbol_keyed_facets_retract`), because rows
  -- attributed through a symbol can be attributed through the WRONG symbol. But `market.price_bar`
  -- is keyed on `security_id`: a bar is filed under the security we asked for, never under the
  -- string we asked with, so a wrong symbol cannot misfile one. The bars we hold are facts about
  -- days the provider did answer, and deleting them over its current silence would lose real data.
  --
  -- What MUST go is the derived layer. `security_return` is a number computed from those bars and
  -- published as current; once we can no longer price the security, continuing to serve it is the
  -- exact failure this schema has already paid for — instruments served `1d = 0.00%` for four days
  -- because the guard that stopped PRODUCING a number could never REMOVE the one already there.
  $ret$ delete from market.security_return where security_id = $1::uuid $ret$,
  'security-prices', 'prices_missing_at',
  true,
  'Daily bars. The ledger holds subject HEALTH here, not the queue — Lane B''s Dagster partitions '
  'are the queue, and this records what asking established.'
)
on conflict (facet) do update set
  ttl = excluded.ttl, absent_ttl = excluded.absent_ttl, backoff = excluded.backoff,
  batch_size = excluded.batch_size, page_size = excluded.page_size,
  control_subject = excluded.control_subject,
  population_sql = excluded.population_sql, retract_sql = excluded.retract_sql,
  enabled = excluded.enabled, note = excluded.note;
