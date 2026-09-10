-- The ISIN resolver should see securities that have NO SYMBOL AT ALL — IDEMPOTENT.
--
-- `pending_yahoo_symbol` qualified a security by "some resource has already failed to fetch it",
-- reading `industry/profile/performance_missing_at`. That misses the population the resolver is
-- most obviously for: a security with an ISIN and no symbol whatsoever. Nothing ever TRIED to fetch
-- it, so none of those flags is set, so it never enters the backlog — and without a symbol it can
-- never enter the others either. A closed loop.
--
-- FOUND VIA EXXON MOBIL. `market.instruments` carries `XOM` and the fund-derived universe holds the
-- security (ISIN US30231G1022) with a CUSIP and no ticker at all, because `security-tickers` asked
-- OpenFIGI on 2026-08-10, got nothing, and set `figi_missing_at` — a 30-day lockout earned by one
-- bad afternoon at a rate-limited provider. A US mega-cap, unreachable in the app, and invisible to
-- the one resource that could have named it.
--
-- Measured 2026-08-12: **485 of 10,060 securities have no symbol** (`security_symbol` holds 9,575),
-- and 5,575 carry `figi_missing_at` — most of those did get a LOCAL symbol from
-- `security-local-symbols`, which is why the symbol-less population is far smaller than the
-- negative-cached one.
--
-- Deliberately NOT clearing `figi_missing_at` wholesale. That flag records a real answer from
-- OpenFIGI and clearing it would re-ask 5,575 ISINs at a rate-limited endpoint to re-derive what we
-- already know. Asking a DIFFERENT provider for the ones that ended up with nothing is the cheaper
-- and more honest move.

drop view if exists market.pending_yahoo_symbol;
create view market.pending_yahoo_symbol as
select
  s.security_id,
  isin.value                        as isin,
  s.country_iso2,
  coalesce(ps.symbol, t.value)      as current_symbol,
  coalesce(max(h.weight), 0)        as best_weight
from market.security s
join market.security_identifier isin
  on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and s.country_iso2 is not null
  and (
        -- A resource asked and got nothing: the symbol we hold may be the wrong spelling.
        s.industry_missing_at     is not null
     or s.profile_missing_at      is not null
     or s.performance_missing_at  is not null
        -- Or nothing can ask at all, because there is no symbol to ask with. This is the case the
        -- view previously could not express, and it is the resolver's whole purpose.
     or coalesce(ps.symbol, t.value) is null
  )
  and (s.yahoo_symbol_missing_at is null or s.yahoo_symbol_missing_at < now() - interval '30 days')
group by s.security_id, isin.value, s.country_iso2, coalesce(ps.symbol, t.value)
-- Symbol-less securities first: they are wholly unreachable, whereas the others at least have a
-- name that might work. `best_weight` still orders within each group, so the heaviest come first.
order by (coalesce(ps.symbol, t.value) is null) desc, best_weight desc;

comment on view market.pending_yahoo_symbol is
  'Securities whose symbol is missing or suspected wrong, with an ISIN to resolve from. Symbol-less first — those cannot enter any other backlog until this one names them.';

grant select on market.pending_yahoo_symbol to service_role;

notify pgrst, 'reload schema';
