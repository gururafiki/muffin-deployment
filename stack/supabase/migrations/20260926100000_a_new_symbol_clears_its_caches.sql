-- A NEW PROVIDER SYMBOL CLEARS THE SYMBOL-KEYED NEGATIVE CACHES, AND A TRIGGER NOW ENFORCES IT.
--
-- A `%_missing_at` mark says "we asked for this security and the provider had nothing". When the
-- mark was set under one spelling and the security then gains another, the mark says nothing about
-- the new one — and until it expires, the security is left out of every backlog keyed on it.
-- `market.clear_symbol_caches` has held that rule since migration 50, and `symbol_cache_
-- classification` says which columns it covers.
--
-- THE RULE LIVED IN TWO CALL SITES AND THE THIRD WRITER NEVER CALLED IT. The edge function's
-- `security-yahoo-symbols` and `security-symbol-repair` cleared the caches by hand after writing a
-- symbol. Dagster's symbology lane took over adoption on 2026-09-24 and does not. Measured on
-- 2026-09-26: of 826 securities whose yfinance symbol the lane adopted, **409 still carried a
-- symbol-keyed mark set BEFORE the adoption** — dividends 301, industry 148, share_stats 77,
-- profile 18, fundamentals 18, statements 17. Each of them was locked out of that family's backlog
-- for up to 30 days, while every resource reported success.
--
-- CLAUDE.md, recorded after the same shape cost the statements backlog: "AN INVARIANT THAT EVERY
-- WRITER MUST REMEMBER IS A TRIGGER." So the rule moves to the table:
--
--   * AFTER INSERT — a security that had no symbol gains one.
--   * AFTER UPDATE OF symbol, only when the value CHANGED — rewriting the same symbol says nothing
--     new, and clearing on it would re-ask a provider for an answer already held.
--   * PROVIDER-AGNOSTIC, like `clear_symbol_caches` itself: its classification decides which
--     columns are symbol-keyed, not this trigger.
--   * SECURITY DEFINER, so whether the invariant holds cannot depend on the writer's grants. The
--     function returns `trigger`, so nothing can call it directly.
--
-- The two edge call sites become redundant rather than wrong: clearing twice is harmless, and both
-- resources are retired later in Phase 3.

create or replace function market.provider_symbol_clears_caches()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'market', 'pg_temp'
as $function$
begin
  if tg_op = 'UPDATE' and old.symbol is not distinct from new.symbol then
    return null;
  end if;
  perform market.clear_symbol_caches(new.security_id);
  return null;
end $function$;

drop trigger if exists security_provider_symbol_clears_caches on market.security_provider_symbol;
-- MUTATION: the trigger is not created

-- A SECOND UNIQUE INDEX ON THE PRIMARY KEY'S OWN COLUMNS. Migration 20260913000000 added
-- `security_provider_symbol_one_per_security (security_id, provider_code)` believing the only
-- unique key was `(provider_code, symbol)`; the primary key has been `(security_id, provider_code)`
-- since the baseline. It enforces nothing the key does not, and costs a write on every insert.
drop index if exists market.security_provider_symbol_one_per_security;

-- THE 409 ALREADY LOCKED OUT, cleared ONCE.
--
-- Only the marks set BEFORE the adoption are cleared, column by column. A mark set AFTER it was
-- asked with the new symbol and is earned; clearing it would re-ask for an absence already proven.
-- The trigger never faces that choice, because at the moment it fires every existing mark predates
-- the new symbol.
--
-- THE COLUMN LIST IS DERIVED FROM `symbol_cache_classification`, never typed out: a hand-written
-- list is exactly how `prices_missing_at` came to be missed and 4,801 equities locked out.
--
-- `identifier_probe.observed_at` is the time of the latest observation, not the first, because a
-- re-ask replaces it. On 2026-09-26 every symbol probe was under a week old, so it is the adoption
-- time; a repair written months later could not assume that.
--
-- ONE-SHOT, because this is a data repair in a set of migrations and must not repeat.
do $$
declare
  n int;
  sets text;
  stale text;
begin
  if exists (select 1 from market.one_shot
              where key = 'clear-marks-older-than-the-adopted-symbol-2026-09-26') then
    raise notice 'clear-marks-older-than-the-adopted-symbol: already applied';
    return;
  end if;

  select string_agg(format('%1$I = case when s.%1$I < a.adopted_at then null else s.%1$I end',
                           column_name), ', ' order by column_name),
         string_agg(format('s.%1$I < a.adopted_at', column_name), ' or ' order by column_name)
    into sets, stale
    from market.symbol_cache_classification
   where symbol_keyed;

  execute format($sql$
    with adopted as (
      select p.security_id, min(p.observed_at) as adopted_at
        from market.identifier_probe p
        join market.security_provider_symbol ps
          on ps.security_id = p.security_id
         and ps.provider_code = 'yfinance'
         and ps.symbol = p.value
       where p.scheme = 'symbol' and p.outcome = 'hit'
       group by p.security_id
    )
    update market.security s
       set %s
      from adopted a
     where a.security_id = s.security_id
       and (%s)
  $sql$, sets, stale);
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'clear-marks-older-than-the-adopted-symbol-2026-09-26',
    format('cleared symbol-keyed marks older than the adopted yfinance symbol on %s securities', n)
  );
  raise notice 'clear-marks-older-than-the-adopted-symbol: % securities', n;
end $$;
