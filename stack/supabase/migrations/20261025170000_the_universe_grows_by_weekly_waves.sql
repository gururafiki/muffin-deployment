-- THE UNIVERSE GROWS BY WEEKLY WAVES OF SHARE CLASSES (Phase 3 Stage 4). Spec: umbrella
-- docs/specs/2026-09-26-finishing-the-universe-family.md. Decided by the user 2026-10-25: open
-- promotion tier 1 except the US (AU, CA, HK, JP, JT, KS, LN, SW), at most 500 a week, checked each
-- week against the price night and the company lane. The US waits for a second source for its
-- directory, Taiwan for the TPEx table.
--
-- WHAT.
--   * `market.promotion_policy`: one row, the wave size (500), the nights a full price pass may take
--     (7, so the Dagster lane can cap a wave by the sweep's capacity) and a pause switch.
--   * `market.exchange.promotion_enabled` for the eight venues.
--   * `market.promotion_candidate`: one row per untracked SHARE CLASS a wave may promote, with the
--     line it is promoted from. Share-class grain, so a company on two boards is one security.
--   * `market.promote_share_classes(p_figis, p_limit)`: promotes the candidates whose line FIGIs it
--     is handed, in the order handed, capped by the policy. The Dagster lane hands it the lines
--     Yahoo's chart priced with a recent bar (decided by the user 2026-10-26), so a wave never
--     mints a line nothing can price.
--
-- WHICH SHARE CLASSES. The directory carries no issuer country, so the home has to be unambiguous
-- from the lines alone: EVERY line of the class is in one country, and that country has an enabled
-- venue. Measured 2026-10-26 over the eight venues, 12,545 untracked classes had one enabled country
-- and no US line, and the rolled-back first wave of five was Tubacex and Miquel y Costas (Spanish,
-- from London's international order book) and Bertrandt, CEWE and AcadeMedia (German and Swedish,
-- from SIX). Their home venues are not enabled, so "one ENABLED country" filed them abroad.
-- Requiring one country for every line leaves 9,215 (JT 2,378, KS 2,392, HK 1,594, AU 1,027,
-- LN 684, CN 671, SW 318, JP 151); the 3,330 it drops are classes with a line abroad, mostly
-- London's. A Bloomberg code for a delisted line (its number and a letter, `7785752Z`, 180 of the
-- 9,215) is skipped so a wave spends no request on it. Whatever else is not a live company
-- (temporary lines such as `ABB LTD-BUY BACK`, Activision on SIX) is left to Yahoo.
-- Ranked by venue tier, then preference, then how many lines the class has (a free prominence
-- proxy: the directory carries no size), then name.
--
-- A LINE YAHOO COULD NOT PRICE is not a candidate for 90 days (`market.promotion_probe`).
--
-- NOT DUPLICATES. A share class already held is excluded, and so is a line whose composite FIGI,
-- provider symbol or ticker a security already holds, the tests `untracked_listing` uses: some
-- tracked securities predate their share-class identifier.
--
-- Guard: tests/a-wave-promotes-each-share-class-once-from-its-home.sql.

create table if not exists market.promotion_policy (
  id              boolean primary key default true,
  wave_size       integer not null,
  max_pass_nights integer not null,
  paused          boolean not null default false,
  reason          text not null,
  constraint promotion_policy_one_row check (id),
  constraint promotion_policy_wave_size check (wave_size > 0),
  constraint promotion_policy_nights check (max_pass_nights > 0)
);

comment on table market.promotion_policy is
  'One row. The most share classes one weekly promotion wave may add, the nights a full price pass '
  'may take (the asset caps a wave by the sweep''s capacity), and a pause switch. Decided 2026-10-25.';

-- SEEDED PAUSED: the first wave is a hand-launched live run of five, read before the policy is
-- unpaused (a control-row edit, in Studio or by the service role). The weekly wave asks nothing of
-- a paused policy and records why.
insert into market.promotion_policy (wave_size, max_pass_nights, paused, reason)
values (500, 7, true,
        'Decided by the user 2026-10-25: at most 500 a week, checked weekly against the price night '
        'and the company lane. Paused until the first live wave of five is verified.')
on conflict (id) do nothing;

grant select, insert, update, delete on market.promotion_policy to service_role;
grant select on market.promotion_policy to ingest_rw, anon, authenticated;
revoke insert, update, delete, truncate on market.promotion_policy from ingest_rw;
alter table market.promotion_policy enable row level security;
drop policy if exists promotion_policy_public_read on market.promotion_policy;
create policy promotion_policy_public_read on market.promotion_policy for select using (true);

-- WHAT YAHOO SAID ABOUT EACH LINE A WAVE ASKED ABOUT, so a line it cannot price is not asked again
-- for 90 days. Without it the weekly probe would re-ask the same unpriceable lines every week, ahead
-- of everything behind them: the head-of-line stall this pipeline has met seven times. Written by
-- the Dagster wave (stage 2) only for answers, and an absence only when a control symbol priced in
-- the same run, so a throttled or broken run records nothing. Keyed by the line's FIGI because the
-- line has no security yet; the provider is a column, as on every ingested row.
create table if not exists market.promotion_probe (
  figi        text primary key references market.venue_listing (figi) on delete cascade,
  outcome     text not null,
  symbol      text not null,
  source_code text not null references market.data_source (code),
  observed_at timestamptz not null,
  constraint promotion_probe_outcome check
    (outcome in ('priced', 'absent', 'empty', 'stale', 'quote_only', 'not_equity', 'not_daily', 'unreadable'))
);

comment on table market.promotion_probe is
  'What the provider answered for each line a promotion wave asked about. A line not priced is not a '
  'candidate again for 90 days. Written by the Dagster asset promotion_wave. Migration 20261025170000.';

grant select, insert, update, delete on market.promotion_probe to service_role, ingest_rw;
grant select on market.promotion_probe to anon, authenticated, metrics_ro;
alter table market.promotion_probe enable row level security;
drop policy if exists promotion_probe_public_read on market.promotion_probe;
create policy promotion_probe_public_read on market.promotion_probe for select using (true);

update market.exchange
   set promotion_enabled = true
 where exch_code in ('AU', 'CN', 'HK', 'JP', 'JT', 'KS', 'LN', 'SW')
   and not promotion_enabled;

do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'promotion_candidate';
  if k = 'm' then execute 'drop materialized view market.promotion_candidate';
  elsif k = 'v' then execute 'drop view market.promotion_candidate';
  end if;
end $$;

create view market.promotion_candidate as
-- ONE PASS, NO JOIN BETWEEN THE LINES AND THEIR CLASSES. Written first as a per-class aggregate
-- joined back to the lines, the view took over 180 s on production's 115,141 live lines: the
-- planner estimated 120 classes past the filter where there are ~12,500 and scanned every line once
-- per class. Window aggregates over the share class read the lines once (0.6 s). One country is
-- `min = max` over the lines, since a window cannot count distinct values.
with live as (
  select v.figi, v.composite_figi, v.share_class_figi, v.exch_code, v.ticker, v.name,
         v.provider_symbol, v.security_type, e.country_iso2, e.promotion_enabled,
         e.promotion_tier, e.preference,
         count(*) over w              as listings,
         min(e.country_iso2) over w   as country_min,
         max(e.country_iso2) over w   as country_max
    from market.venue_listing v
    join market.exchange e on e.exch_code = v.exch_code
   where v.absent_since is null
     and v.share_class_figi is not null
  window w as (partition by v.share_class_figi)
),
chosen as (
  select distinct on (l.share_class_figi) l.*
    from live l
   where l.promotion_enabled
     and l.country_min = l.country_max
     and l.name is not null
     and l.security_type in ('Common Stock', 'REIT')
     and l.ticker !~ '^[0-9]{5,}[A-Z]$'
   order by l.share_class_figi, l.preference, l.exch_code, l.figi
)
select ch.share_class_figi, ch.figi, ch.composite_figi, ch.exch_code, ch.ticker, ch.name,
       ch.country_iso2, ch.provider_symbol, ch.security_type, ch.promotion_tier, ch.preference,
       ch.listings
  from chosen ch
 where not exists (select 1 from market.security_identifier si
                    where si.kind_code = 'share_class_figi' and si.value = ch.share_class_figi)
   and not exists (select 1 from market.security_identifier si
                    where si.kind_code = 'figi' and si.value = coalesce(ch.composite_figi, ch.figi))
   and not exists (select 1 from market.security_provider_symbol ps
                    where upper(ps.symbol) = upper(ch.provider_symbol))
   and not exists (select 1 from market.security_identifier ti
                    where ti.kind_code = 'ticker' and upper(ti.value) = upper(ch.provider_symbol))
   and not exists (select 1 from market.promotion_probe pp
                    where pp.figi = ch.figi and pp.outcome <> 'priced'
                      and pp.observed_at > now() - interval '90 days');

comment on view market.promotion_candidate is
  'Untracked share classes a promotion wave may add, one row each, with the line it is promoted '
  'from: common stock or REITs whose every line is in one country with an enabled venue, and whose '
  'line Yahoo has not refused in 90 days. Read by market.promote_share_classes. '
  'Migration 20261025170000.';

grant select on market.promotion_candidate to service_role, ingest_rw, metrics_ro, anon, authenticated;

drop function if exists market.promote_share_classes(text[], integer);
create function market.promote_share_classes(p_figis text[], p_limit integer)
 returns jsonb
 language plpgsql
 set search_path to 'market', 'pg_catalog'
as $function$
declare
  v_policy  market.promotion_policy;
  v_limit   integer;
  v_done    integer;
  v_venues  jsonb;
begin
  select * into v_policy from market.promotion_policy where id;
  if v_policy.id is null then
    return jsonb_build_object('promoted', 0, 'reason', 'no promotion policy');
  end if;
  if v_policy.paused then
    return jsonb_build_object('promoted', 0, 'reason', 'paused');
  end if;
  v_limit := greatest(0, least(coalesce(p_limit, 0), v_policy.wave_size));
  if v_limit = 0 then
    return jsonb_build_object('promoted', 0, 'reason', 'no capacity', 'asked', p_limit);
  end if;

  -- THE LINES HANDED IN ARE STILL CHECKED AGAINST THE CANDIDATES, so a class promoted since the
  -- caller chose them, or a line the directory has stopped returning, is skipped rather than
  -- minted twice. THEIR ORDER IS THE WAVE'S: the caller asked the provider in candidate order, and
  -- a line it could not verify is simply absent from the array.
  --
  -- ONE STATEMENT, NO TEMP TABLE. A temp table belongs to whichever role created it, so a second
  -- wave in one session, as another role, cannot drop it (measured in the guard: "must be owner of
  -- table wave"). Data-modifying CTEs run to completion whether or not the outer query reads them,
  -- and the foreign keys are checked at the end of the statement, when every security exists.
  --
  -- ONE CANDIDATE PER PRICE SYMBOL: `security_provider_symbol` is unique on (provider, symbol), and
  -- two rows of one statement claiming one symbol would fail the whole wave.
  with wave as materialized (
    select gen_random_uuid() as security_id, c.*
      from (select distinct on (upper(coalesce(pc.provider_symbol, pc.figi)))
                   pc.*, array_position(p_figis, pc.figi) as position
              from market.promotion_candidate pc
             where pc.figi = any (p_figis)
             order by upper(coalesce(pc.provider_symbol, pc.figi)),
                      array_position(p_figis, pc.figi)) c
     order by c.position
     limit v_limit
  ),
  securities as (
    insert into market.security (security_id, name, security_type_code, country_iso2, is_tradeable)
    select w.security_id, w.name, 'equity', w.country_iso2, true from wave w
    returning security_id
  ),
  identifiers as (
    insert into market.security_identifier (kind_code, value, security_id, source_code)
    select 'share_class_figi', w.share_class_figi, w.security_id, 'openfigi' from wave w
    union all
    select 'figi', coalesce(w.composite_figi, w.figi), w.security_id, 'openfigi' from wave w
    union all
    select 'ticker', upper(w.ticker), w.security_id, 'openfigi' from wave w where w.ticker is not null
    on conflict (kind_code, value) do nothing
    returning 1
  ),
  symbols as (
    insert into market.security_provider_symbol (security_id, provider_code, symbol)
    select w.security_id, 'yfinance', w.provider_symbol from wave w where w.provider_symbol is not null
    on conflict (security_id, provider_code) do nothing
    returning 1
  )
  select (select count(*) from securities),
         coalesce((select jsonb_object_agg(exch_code, n)
                     from (select exch_code, count(*) as n from wave group by exch_code) x), '{}')
    into v_done, v_venues;

  return jsonb_build_object(
    'promoted', v_done,
    'handed', coalesce(cardinality(p_figis), 0),
    'asked', p_limit,
    'wave_size', v_policy.wave_size,
    'by_venue', v_venues,
    'candidates_left', (select count(*) from market.promotion_candidate));
end;
$function$;

revoke execute on function market.promote_share_classes(text[], integer) from public;
grant execute on function market.promote_share_classes(text[], integer) to ingest_rw, service_role;
