-- 8,169 OF 11,573 MARKET CAPS (71%) ARE DENOMINATED IN SOMETHING OTHER THAN DOLLARS,
-- AND NOTHING CAN COMPARE THEM.
--
-- `security.market_cap` is stored in the security's OWN currency — Samsung's is ₩1,802tn, COSCO's
-- is ¥234bn — because that is what the provider reports and converting at write time would bake a
-- rate into a stored fact. The consequence is that the universe cannot be ranked, filtered or
-- bucketed by size across markets, and it is why `market-verify`'s mega-cap canary is US-only and
-- therefore blind to non-US securities, to securities below $50bn, and to the 34% with no cap at
-- all. That blindness let 85 significant holdings be wrongly marked on 2026-08-14 while the canary
-- read "0 of 213".
--
-- ONE SOURCE, NOT TWO, and that was measured rather than assumed. The obvious choice is the ECB's
-- free daily reference rates, and it is not enough: measured 2026-08-18 it publishes 30 currencies
-- and covers **27 of our 41**, missing TWD (535 Taiwanese securities), VND, AED, SAR, QAR, KWD,
-- PEN, CLP, COP, ARS and GEL. Yahoo's chart endpoint — already used by `security-yahoo-symbols`,
-- keyless, same host — returns ALL of them, spot-checked against known pegs:
--
--   KWDUSD 3.2573   the Kuwaiti dinar, the world's highest-value currency
--   SARUSD 0.2664   3.75 SAR/USD, the riyal's peg
--   AEDUSD 0.2723   3.67 AED/USD, the dirham's peg
--   TWDUSD 0.0314   ~31.9 TWD/USD
--   VNDUSD 0.0000382  ~26,200 VND/USD
--
-- So a second provider would add failure modes and cover a strict subset. One source it is.
--
-- THREE OF OUR "CURRENCIES" ARE NOT CURRENCIES — they are SUBUNITS, and this is the same fact that
-- made Tel Aviv prices look like a 100x market crash:
--
--   ILA = 1/100 ILS   (agorot)      ZAC = 1/100 ZAR   (cents)     KWF = 1/1000 KWD  (fils)
--
-- They are stored as ordinary rows with a derived rate rather than as a special case, so a caller
-- converting a figure never has to know which of the 41 are subunits. `derived_from` records that
-- the row was computed rather than quoted, because a derived rate and a quoted one are different
-- facts and a reader is entitled to tell them apart.

create table if not exists market.fx_rate (
  currency_code text not null references market.currency (code),
  as_of         date not null,
  -- USD PER ONE UNIT, not units per USD. Both spellings are common and they are reciprocals, so
  -- the direction is in the column name: a figure in currency X is multiplied by this to reach USD.
  -- Stated because getting it backwards is silent — JPY at 0.0064 and 155 are both plausible-
  -- looking numbers and only one of them turns ¥1bn into $6.4m rather than $155bn.
  usd_per_unit  numeric not null check (usd_per_unit > 0),
  source_code   text not null references market.data_source (code),
  -- Null when quoted directly. Set to the parent currency when this row is a SUBUNIT computed from
  -- it (ILA from ILS, ZAC from ZAR, KWF from KWD).
  derived_from  text references market.currency (code),
  primary key (currency_code, as_of)
);

comment on column market.fx_rate.usd_per_unit is
  'USD per ONE unit of this currency — multiply a figure in this currency by it to reach USD. The reciprocal spelling is equally common and equally plausible-looking, which is why the direction is in the name.';
comment on column market.fx_rate.derived_from is
  'The parent currency when this row is a SUBUNIT (ILA=ILS/100, ZAC=ZAR/100, KWF=KWD/1000). NULL when the rate was quoted directly. A derived rate and a quoted one are different facts.';

create index if not exists fx_rate_as_of_idx on market.fx_rate (as_of desc);

-- The latest rate per currency — what a caller almost always wants.
--
-- DEPENDENT DROPPED FIRST. `security_market_cap_usd` is built on this view, so dropping this one
-- alone fails on the SECOND pass with `cannot drop view because other objects depend on it` —
-- after the first pass has already succeeded, which is the shape that has broken deploys here
-- before (migration 35 exists because a hand-maintained dependent list was wrong three times in
-- one afternoon). Caught by the three-pass migration test rather than in production.
drop view if exists market.security_market_cap_usd;
drop view if exists market.fx_rate_current;
create view market.fx_rate_current as
select distinct on (currency_code)
  currency_code, as_of, usd_per_unit, source_code, derived_from
from market.fx_rate
order by currency_code, as_of desc;

-- Market cap in a COMPARABLE unit, alongside the native figure rather than replacing it.
--
-- NULL when no rate is known, never a fallback to the native number: silently treating ₩1,802tn as
-- $1,802tn would be wrong by three orders of magnitude and look like the largest company on earth.
-- That is the same failure as the hardcoded `$` that rendered Alibaba's CNY revenue as $1.02tn.
drop view if exists market.security_market_cap_usd;
create view market.security_market_cap_usd as
select
  s.security_id,
  s.market_cap                          as market_cap_native,
  s.currency_code,
  case
    when s.market_cap is null then null
    when s.currency_code = 'USD' then s.market_cap
    else s.market_cap * fx.usd_per_unit
  end                                   as market_cap_usd,
  fx.as_of                              as fx_as_of
from market.security s
left join market.fx_rate_current fx on fx.currency_code = s.currency_code;

-- BOTH ROLES ON BOTH VIEWS. Granting the views to `anon` alone left `service_role` with
-- `permission denied for view fx_rate_current` — measured immediately after this deployed, and
-- invisible until something read them as the ingest role, which nothing does YET. service_role has
-- BYPASSRLS, which is not a table privilege and grants nothing here.
grant select on market.fx_rate, market.fx_rate_current, market.security_market_cap_usd
  to anon, authenticated, service_role;
grant select, insert, update, delete on market.fx_rate to service_role;

alter table market.fx_rate enable row level security;
do $$ begin
  create policy fx_rate_public_read on market.fx_rate for select using (true);
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
