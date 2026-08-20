-- YFINANCE REPORTS `currency: USD` FOR SECURITIES QUOTED IN RUPIAH, AND WE BELIEVED IT.
--
-- Found 2026-08-18 by building FX and looking at the result: `security_market_cap_usd` ranked
-- PT Barito Renewables as the largest company on earth at **$442 trillion**, about four times world
-- GDP. The figure is 442.8tn IDR (~$27bn, correct); the currency label is wrong.
--
-- Our code is faithful and the provider is not. `equity/fundamental/metrics` for `BREN.JK` returns
-- `currency: USD` alongside `market_cap: 442810222247936` and `price_to_book: 662000` — internally
-- inconsistent within one response.
--
-- ── THE FIRST VERSION OF THIS MIGRATION WAS DANGEROUS AND WAS NEVER APPLIED ────────────────────
--
-- It relabelled a security whenever its currency disagreed with its venue's MAJORITY currency.
-- Measured before it landed, that rule would have rewritten **233 securities of which only ~20
-- were actually wrong**:
--
--   732.HK    HKD -> CNY   Hong Kong genuinely has HKD, CNY and USD counters
--   SSW.JO    ZAC -> ZAR   Johannesburg quotes in CENTS — a 100x error
--   ZAIN.KW   KWF -> KWD   Kuwait quotes in FILS — a 1000x error
--   BBD/B.TO  USD -> CAD   Toronto genuinely lists USD-denominated securities
--
-- Two classes of legitimate data fail a majority vote: venues with real multi-currency listings,
-- and venues quoted in a SUBUNIT where both the subunit and its parent appear. **A majority says
-- what is COMMON on a venue; this needed what is POSSIBLE, and they are different questions.**
-- The Jakarta evidence was real and the generalisation drawn from it was not.
--
-- The deploy carrying it was cancelled mid-run and verified against the nightly backup: 27,629
-- securities compared, **0 differences**. Nothing was altered.
--
-- ── WHAT THIS DOES INSTEAD ────────────────────────────────────────────────────────────────────
--
-- The narrow rule, which is all the evidence ever supported: a USD claim on a NON-US venue with a
-- market cap above $2tn. The largest real company is ~$5.5tn and US-listed — NVDA is REAL and sits
-- BETWEEN two fakes (241560.KS $6,087bn, HCLT.NS $3,707bn), so magnitude alone cannot be the test
-- either. Neither signal works alone; both together do.
--
-- AND IT RECORDS WHAT IT OVERWRITES. The first version was an UPDATE with no record of the prior
-- value; it only looked recoverable because `security_fundamentals.raw.currency` happened to
-- retain the provider's claim, which is luck rather than design. A repair that overwrites must
-- capture what it overwrote, in the same transaction, or it is not reversible.

create table if not exists market.currency_repair (
  security_id   uuid not null references market.security (security_id) on delete cascade,
  repaired_at   timestamptz not null default now(),
  previous_code text,
  new_code      text not null,
  reason        text not null,
  primary key (security_id, repaired_at)
);

comment on table market.currency_repair is
  'Every automated change to security.currency_code, with the value it replaced. A repair that cannot be undone from the database itself is not a repair — the first version of migration 74 overwrote 233 rows with no record and was only recoverable by accident.';

grant select on market.currency_repair to anon, authenticated, service_role;
grant insert on market.currency_repair to service_role;
alter table market.currency_repair enable row level security;
do $$ begin
  create policy currency_repair_public_read on market.currency_repair for select using (true);
exception when duplicate_object then null; end $$;

-- ── the venue's own currency, DERIVED rather than authored ────────────────────────────────────
--
-- Kept because it is a correct and useful description of what a venue commonly trades in, and
-- deriving it means a new venue needs no migration and nobody has to remember what Jakarta trades
-- in. It is simply NOT licensed to overrule a provider on its own — see above.
drop view if exists market.security_market_cap_usd;
drop view if exists market.venue_currency;
create view market.venue_currency as
with quoted as (
  select
    substring(sym.symbol from position('.' in sym.symbol)) as suffix,
    s.currency_code
  from market.security s
  join market.security_symbol sym on sym.security_id = s.security_id
  where s.currency_code is not null
    and position('.' in sym.symbol) > 0
),
tallied as (
  select suffix, currency_code, count(*) as n,
         sum(count(*)) over (partition by suffix) as venue_total
    from quoted
   group by suffix, currency_code
)
select distinct on (suffix)
  suffix,
  currency_code as quote_currency,
  n             as agreeing,
  venue_total   as securities
from tallied
where venue_total >= 5
  and n::numeric / venue_total > 0.60
order by suffix, n desc;

comment on view market.venue_currency is
  'The currency each venue MOST COMMONLY trades in, derived by majority from securities we hold. Descriptive only: it may not overrule a provider by itself, because Hong Kong, Toronto and SIX all carry legitimate multi-currency listings and Johannesburg and Kuwait quote in subunits. Used only in combination with an impossible market cap.';

grant select on market.venue_currency to anon, authenticated, service_role;

-- `security_market_cap_usd` was dropped above (it depends on nothing here, but dropping a view
-- whose dependents exist fails on the SECOND pass, which is how migration 73 broke its own re-run).
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

grant select on market.security_market_cap_usd to anon, authenticated, service_role;

-- ── the narrow repair, which records what it replaces ─────────────────────────────────────────
do $$
declare
  fixed bigint;
begin
  if exists (select 1 from market.one_shot where key = '74-relabel-impossible-usd-caps') then
    return;
  end if;

  with impossible as (
    select s.security_id, s.currency_code as previous_code, vc.quote_currency as new_code
      from market.security s
      join market.security_symbol sym on sym.security_id = s.security_id
      join market.venue_currency vc
        on vc.suffix = substring(sym.symbol from position('.' in sym.symbol))
     where s.currency_code = 'USD'
       and vc.quote_currency <> 'USD'
       and s.market_cap > 2e12
       and position('.' in sym.symbol) > 0
  ),
  logged as (
    insert into market.currency_repair (security_id, previous_code, new_code, reason)
    select security_id, previous_code, new_code,
           'USD claimed on a non-US venue with a market cap above $2tn (migration 74)'
      from impossible
    returning security_id, new_code
  )
  update market.security s
     set currency_code = l.new_code
    from logged l
   where s.security_id = l.security_id;

  get diagnostics fixed = row_count;

  insert into market.one_shot (key, reason) values
    ('74-relabel-impossible-usd-caps',
     format('Relabelled %s securities claiming USD on a non-US venue with a market cap above $2tn. '
            || 'The largest real company is ~$5.5tn and US-listed, so a suffixed symbol at this '
            || 'scale is a unit error rather than a company — PT Barito read $442tn, 4x world GDP. '
            || 'Prior values are in market.currency_repair.', fixed));
end $$;

notify pgrst, 'reload schema';
