-- A WAVE ASKS EACH SPELLING ITS COUNTRY USES, AND PROMOTES THE ONE YAHOO PRICED.
-- Decided by the user 2026-10-26, after the first live wave (muffin-ingest#132, run 4eb5e801).
--
-- WHY. The live wave of five priced both Japanese lines and refused all three Korean ones: they
-- are KOSDAQ companies, which Yahoo spells `.KQ`, and the KS composite the directory sweeps files
-- KOSPI and KOSDAQ alike under `.KS`. OpenFIGI's filter pages carry a bare `KS` on all 2,815 lines,
-- so nothing in the directory tells the two markets apart. Measured over the 9,031 candidates the
-- same evening, two more shapes Yahoo would refuse:
--   * Hong Kong: 325 of 1,584 tickers have 1-3 digits; Yahoo wants four (`883` is `0883.HK`, as the
--     tracked `0016.HK` already is).
--   * Canada: 293 of 592 tickers carry Bloomberg's share-class `/` (`BEK/B`), which Yahoo spells
--     `BEK-B`; and the composite also holds TSX Venture (`.V`) and CSE (`.CN`) lines.
-- A refusal under the wrong name would have kept each of them out for 90 days: this file's "a
-- wrong name is not a missing security", met again.
--
-- THE FIX. The Dagster probe generates the spellings and asks Yahoo each in turn, moving to the
-- next only when Yahoo states it does not know the symbol. The ticker forms (`/` to `-`, Hong
-- Kong's four digits) are code in `muffin_ingest.facets.promotion`; the suffixes each country uses
-- are data, here:
--   * `market.yahoo_spelling`: the suffixes per country, in the order asked. A country with no
--     row is asked under the directory's own spelling only.
--   * `market.promote_share_classes(p_figis, p_symbols, p_limit)`: each line is promoted with the
--     spelling Yahoo priced. A symbol another security already holds is skipped and counted,
--     because `security_provider_symbol` is unique on it.
--   * Every `promotion_probe` row not `priced` is deleted once: each was asked under the
--     directory's spelling only (the three KOSDAQ lines of the live wave).
--
-- Guard: tests/a-wave-promotes-each-share-class-once-from-its-home.sql.

create table if not exists market.yahoo_spelling (
  country_iso2 text not null references market.countries (iso2),
  suffix       text not null,
  preference   smallint not null,
  reason       text not null,
  primary key (country_iso2, suffix),
  constraint yahoo_spelling_suffix check (suffix ~ '^\.[A-Z]+$')
);

comment on table market.yahoo_spelling is
  'The suffixes Yahoo spells a country''s listings with, in the order a promotion probe asks them. '
  'A control table: a country Yahoo spells several ways (Korea, Canada) lists each. '
  'Migration 20261026130000.';

insert into market.yahoo_spelling (country_iso2, suffix, preference, reason)
select v.country_iso2, v.suffix, v.preference, v.reason
  from (values
    ('AU', '.AX', 1, 'ASX'),
    ('CA', '.TO', 1, 'Toronto Stock Exchange'),
    ('CA', '.V',  2, 'TSX Venture, filed under the CN composite with Toronto'),
    ('CA', '.CN', 3, 'Canadian Securities Exchange'),
    ('CA', '.NE', 4, 'Cboe Canada (NEO)'),
    ('CH', '.SW', 1, 'SIX Swiss Exchange'),
    ('GB', '.L',  1, 'London Stock Exchange, including AIM'),
    ('HK', '.HK', 1, 'Hong Kong Exchanges; tickers are four digits'),
    ('JP', '.T',  1, 'Tokyo Stock Exchange'),
    ('KR', '.KS', 1, 'KOSPI'),
    ('KR', '.KQ', 2, 'KOSDAQ, filed under the KS composite with KOSPI')
  ) as v (country_iso2, suffix, preference, reason)
 where exists (select 1 from market.countries c where c.iso2 = v.country_iso2)
on conflict (country_iso2, suffix) do nothing;

grant select, insert, update, delete on market.yahoo_spelling to service_role;
grant select on market.yahoo_spelling to ingest_rw, anon, authenticated, metrics_ro;
revoke insert, update, delete, truncate on market.yahoo_spelling from ingest_rw;
alter table market.yahoo_spelling enable row level security;
drop policy if exists yahoo_spelling_public_read on market.yahoo_spelling;
create policy yahoo_spelling_public_read on market.yahoo_spelling for select using (true);

drop function if exists market.promote_share_classes(text[], integer);
drop function if exists market.promote_share_classes(text[], text[], integer);
create function market.promote_share_classes(p_figis text[], p_symbols text[], p_limit integer)
 returns jsonb
 language plpgsql
 set search_path to 'market', 'pg_catalog'
as $function$
declare
  v_policy  market.promotion_policy;
  v_limit   integer;
  v_done    integer;
  v_held    integer;
  v_venues  jsonb;
begin
  select * into v_policy from market.promotion_policy where id;
  if v_policy.id is null then
    return jsonb_build_object('promoted', 0, 'reason', 'no promotion policy');
  end if;
  if v_policy.paused then
    return jsonb_build_object('promoted', 0, 'reason', 'paused');
  end if;
  if coalesce(cardinality(p_figis), 0) <> coalesce(cardinality(p_symbols), 0) then
    raise exception 'promote_share_classes: % lines and % symbols; each line needs the spelling Yahoo priced',
      coalesce(cardinality(p_figis), 0), coalesce(cardinality(p_symbols), 0);
  end if;
  v_limit := greatest(0, least(coalesce(p_limit, 0), v_policy.wave_size));
  if v_limit = 0 then
    return jsonb_build_object('promoted', 0, 'reason', 'no capacity', 'asked', p_limit);
  end if;

  -- A SPELLING ANOTHER SECURITY ALREADY HOLDS is skipped and counted: the directory can offer a
  -- class whose tracked twin predates its share-class identifier, and its verified spelling is the
  -- twin's symbol. Minting it would fail the whole wave on the unique key.
  select count(*) into v_held
    from unnest(p_figis, p_symbols) as h (figi, symbol)
   where exists (select 1 from market.security_provider_symbol ps where upper(ps.symbol) = upper(h.symbol));

  -- THE LINES HANDED IN ARE STILL CHECKED AGAINST THE CANDIDATES, so a class promoted since the
  -- caller chose them, or a line the directory has stopped returning, is skipped rather than
  -- minted twice. THEIR ORDER IS THE WAVE'S: the caller asked the provider in candidate order, and
  -- a line it could not verify is simply absent from the arrays.
  --
  -- ONE STATEMENT, NO TEMP TABLE. A temp table belongs to whichever role created it, so a second
  -- wave in one session, as another role, cannot drop it (measured in the guard: "must be owner of
  -- table wave"). Data-modifying CTEs run to completion whether or not the outer query reads them,
  -- and the foreign keys are checked at the end of the statement, when every security exists.
  --
  -- ONE CANDIDATE PER PRICE SYMBOL: `security_provider_symbol` is unique on (provider, symbol), and
  -- two rows of one statement claiming one symbol would fail the whole wave.
  with handed as (
    select h.figi, h.symbol, h.position
      from unnest(p_figis, p_symbols) with ordinality as h (figi, symbol, position)
     where h.symbol is not null
       and not exists (select 1 from market.security_provider_symbol ps
                        where upper(ps.symbol) = upper(h.symbol))
  ),
  wave as materialized (
    select gen_random_uuid() as security_id, c.*
      from (select distinct on (upper(h.symbol)) pc.*, h.symbol as yahoo_symbol, h.position
              from market.promotion_candidate pc
              join handed h on h.figi = pc.figi
             order by upper(h.symbol), h.position) c
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
    select w.security_id, 'yfinance', w.yahoo_symbol from wave w
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
    'symbol_held', v_held,
    'asked', p_limit,
    'wave_size', v_policy.wave_size,
    'by_venue', v_venues,
    'candidates_left', (select count(*) from market.promotion_candidate));
end;
$function$;

revoke execute on function market.promote_share_classes(text[], text[], integer) from public;
grant execute on function market.promote_share_classes(text[], text[], integer) to ingest_rw, service_role;

-- ONCE: every refusal recorded so far was asked under the directory's spelling only.
delete from market.promotion_probe where outcome <> 'priced';
