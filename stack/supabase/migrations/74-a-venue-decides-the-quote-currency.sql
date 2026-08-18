-- YFINANCE REPORTS `currency: USD` FOR SECURITIES QUOTED IN RUPIAH, AND WE BELIEVED IT.
--
-- Found 2026-08-18 by building FX and looking at the result. `security_market_cap_usd` ranked
-- PT Barito Renewables as the largest company on earth at **$442 trillion** — roughly four times
-- world GDP. The figure is 442.8tn IDR (~$27bn, which is right); the currency label is wrong.
--
-- OUR CODE IS FAITHFUL AND THE PROVIDER IS NOT. `equity/fundamental/metrics` for `BREN.JK` returns
-- `currency: USD` alongside `market_cap: 442810222247936` and `price_to_book: 662000` — internally
-- inconsistent in the response itself. 24 Indonesian listings, plus Chilean (ENELAM.SN), Korean
-- (241560.KS) and Indian (HCLT.NS) ones, arrived the same way.
--
-- MAGNITUDE CANNOT BE THE TEST, and that is the trap this nearly fell into:
--
--   NVDA        $5,464bn   REAL
--   241560.KS   $6,087bn   fake (KRW, ~$4.3bn)
--   HCLT.NS     $3,707bn   fake (INR, ~$39bn)
--
-- A real mega-cap sits BETWEEN two fakes, so no threshold separates them. The venue does: a
-- security trading on Jakarta is quoted in rupiah, and `.JK` says so.
--
-- THE VENUE'S CURRENCY IS DERIVED FROM OUR OWN DATA, NOT AUTHORED. Measured on `.JK`: 72 securities
-- say IDR and 24 say USD. The majority is the venue's currency and the minority is the defect —
-- and deriving it means a new venue needs no migration and no one has to remember what Jakarta
-- trades in. Authoring that table from memory is exactly how the venue map drifted to 54 rows
-- against 38, and how Taiwan lost 534 securities.
--
-- The threshold is deliberately conservative: a venue must have at least 5 securities and a clear
-- majority (>60%) before it is allowed to contradict a provider. A venue we barely know cannot
-- overrule anyone.

drop view if exists market.venue_currency;
create view market.venue_currency as
with quoted as (
  select
    -- The suffix, i.e. everything from the last dot. A bare symbol is US and is excluded: the US
    -- genuinely quotes in USD, so it can neither be wrong nor teach us anything.
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
  'The quote currency of each venue, DERIVED by majority from securities we already hold rather than authored. A venue needs 5+ securities and a >60% majority before it may contradict a provider. Measured 2026-08-18: .JK is 72 IDR against 24 USD, and the 24 are the defect.';

grant select on market.venue_currency to anon, authenticated, service_role;

-- ── the repair ────────────────────────────────────────────────────────────────────────────────
--
-- ONE-SHOT, because it is a data repair and migrations re-run on every deploy. The forward fix
-- belongs to the resource, which now refuses a provider currency the venue contradicts.
--
-- Only the CURRENCY is corrected, never the market cap. The cap is a real number in the real
-- currency — 442.8tn IDR is Barito's actual capitalisation — so relabelling it is the whole fix.
-- Scaling it would invent a figure.
do $$
declare
  fixed bigint;
begin
  if exists (select 1 from market.one_shot where key = '74-relabel-currency-from-venue') then
    return;
  end if;

  with wrong as (
    select s.security_id, vc.quote_currency
      from market.security s
      join market.security_symbol sym on sym.security_id = s.security_id
      join market.venue_currency vc
        on vc.suffix = substring(sym.symbol from position('.' in sym.symbol))
     where s.currency_code is distinct from vc.quote_currency
       and position('.' in sym.symbol) > 0
  )
  update market.security s
     set currency_code = w.quote_currency
    from wrong w
   where s.security_id = w.security_id;

  get diagnostics fixed = row_count;

  insert into market.one_shot (key, reason) values
    ('74-relabel-currency-from-venue',
     format('Relabelled %s securities whose stored currency contradicted their venue. yfinance '
            || 'reports currency USD for Jakarta-quoted securities, which made PT Barito the '
            || 'largest company on earth at $442tn once FX conversion existed. Only the label was '
            || 'changed; the market cap is a real figure in the real currency.', fixed));
end $$;

notify pgrst, 'reload schema';
