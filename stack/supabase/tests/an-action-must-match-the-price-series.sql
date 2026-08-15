-- The corporate-action backlog must only offer securities whose US ticker IS their priced symbol.
--
-- WHY. Tiingo is asked by US ticker — the only symbology it carries — while `security_price` and
-- `market.performance` are keyed on `security_symbol`, the PRIMARY listing. Migration 67 shipped
-- without requiring those to agree, and the first live run showed they do not for **33 of 45**
-- securities: SSNLF vs 005930.KS, NONOF vs NOVO-B.CO, ASMLF vs ASML.AS, BUDFF vs ABI.BR.
--
-- Both uses of this data break on that mismatch, and neither breaks loudly:
--
--   * a cash dividend on the OTC line is in USD while Samsung's series is in KRW — a total return
--     computed from it is wrong by three orders of magnitude, not merely imprecise
--   * an ADR ratio change moves the depositary line and not the underlying, so back-adjusting a
--     local series by it INTRODUCES a discontinuity
--
-- The migration set applies cleanly against an empty database either way, because a view with no
-- rows joins nothing. So the constraint is asserted here with the four shapes that matter.

\set ON_ERROR_STOP on

begin;

insert into market.security (security_id, name, security_type_code) values
  -- Priced off its own US line: the action and the series describe one listing.
  ('00000000-0000-0000-0000-0000000068a1', 'T68 US listed',    'equity'),
  -- The Samsung shape: US ticker exists, but the security is priced off its local line.
  ('00000000-0000-0000-0000-0000000068a2', 'T68 Local priced', 'equity'),
  -- No US ticker at all — Tiingo has nothing to be asked for.
  ('00000000-0000-0000-0000-0000000068a3', 'T68 No ticker',    'equity'),
  -- Already has recent actions; the 30-day window must exclude it.
  ('00000000-0000-0000-0000-0000000068a4', 'T68 Recent',       'equity')
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-0000000068a1', 'ticker', 'T68US'),
  ('00000000-0000-0000-0000-0000000068a2', 'ticker', 'T68OTC'),
  ('00000000-0000-0000-0000-0000000068a4', 'ticker', 'T68REC')
on conflict (kind_code, value) do nothing;

-- `security_symbol` prefers a PRIMARY listing over the ticker, which is what creates the mismatch.
insert into market.listing (security_id, exch_code, provider_symbol, is_primary) values
  ('00000000-0000-0000-0000-0000000068a2', 'KS', 'T68LOCAL.KS', true)
on conflict do nothing;
insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-0000000068a4', 'yfinance', 'T68REC')
on conflict (security_id, provider_code) do nothing;

insert into market.data_source (code, name) values ('tiingo','Tiingo') on conflict (code) do nothing;
insert into market.security_corporate_action
  (security_id, ex_date, kind, value, observed_symbol, source_code, as_of) values
  ('00000000-0000-0000-0000-0000000068a4', '2026-01-02', 'dividend', 0.5, 'T68REC', 'tiingo', now())
on conflict do nothing;

do $$
declare
  bad text;
begin
  select string_agg(format('%s: %s, expected %s', e.name,
                           case when p.security_id is null then 'not offered' else 'offered' end,
                           e.want), '; ')
    into bad
  from (values
    ('00000000-0000-0000-0000-0000000068a1'::uuid, 'T68 US listed',    'offered'),
    ('00000000-0000-0000-0000-0000000068a2'::uuid, 'T68 Local priced', 'not offered'),
    ('00000000-0000-0000-0000-0000000068a3'::uuid, 'T68 No ticker',    'not offered'),
    ('00000000-0000-0000-0000-0000000068a4'::uuid, 'T68 Recent',       'not offered')
  ) e(security_id, name, want)
  left join market.pending_corporate_actions p on p.security_id = e.security_id
  where (case when p.security_id is null then 'not offered' else 'offered' end)
        is distinct from e.want;

  if bad is not null then
    raise exception 'pending_corporate_actions offers the wrong securities: %. An action fetched '
                    'by US ticker cannot be applied to a series priced off a different listing.', bad;
  end if;
  raise notice 'ok  only securities priced off their own US ticker are offered';
end $$;

rollback;
