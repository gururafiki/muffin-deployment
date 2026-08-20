-- A CORPORATE ACTION IS ONLY USABLE AGAINST THE LISTING IT WAS OBSERVED ON.
--
-- Migration 67 shipped `security-corporate-actions` and its first live run wrote 521 rows across 45
-- securities. Verifying them found the defect: the resource asks Tiingo by the **US ticker** (the
-- only symbology Tiingo carries), while `security_price` stores bars for the security's **primary
-- listing** — and those are different for **33 of the 45**:
--
--   asked SSNLF  -> priced 005930.KS      asked NONOF  -> priced NOVO-B.CO
--   asked ASMLF  -> priced ASML.AS        asked BUDFF  -> priced ABI.BR
--   asked DBSDF  -> priced D05.SI         asked NOKBF  -> priced NOKIA.HE
--
-- Both intended uses break on that mismatch:
--
--   * a CASH DIVIDEND on the OTC line is in USD; Samsung's prices are in KRW, so storing `0.27`
--     against it is wrong by three orders of magnitude, and total return computed from it is
--     nonsense rather than merely imprecise
--   * an ADR RATIO CHANGE moves the depositary line and not the underlying, so back-adjusting a
--     local series by it would introduce a discontinuity rather than remove one
--
-- The rows are not salvageable by inspection — nothing on them records which listing they came
-- from — so they are deleted and re-earned. One run's data, one day old.
--
-- TWO CHANGES make it correct rather than merely smaller:
--
--   1. `observed_symbol` is stored. An action without the listing it was seen on cannot be checked,
--      which is how this survived a full review and a green test suite.
--   2. The backlog only offers securities whose US ticker IS their priced symbol, so an action and
--      the series it will be applied to always describe the same listing.
--
-- THE COST IS COVERAGE, AND IT IS THE RIGHT TRADE. This drops from ~6,645 US-tickered securities to
-- those actually priced off their US line. Samsung keeps its KRW prices and gains no dividend
-- record — which is honest, because Tiingo has no Korean data and the US OTC line's dividend is a
-- different number about a different instrument. A wrong dividend is worse than none: this file's
-- own currency work exists because a figure carrying the wrong unit read as authoritative.

alter table market.security_corporate_action
  add column if not exists observed_symbol text;

comment on column market.security_corporate_action.observed_symbol is
  'The symbol this action was observed on — always the US ticker, since that is the only symbology Tiingo carries. Kept so a consumer can verify the action describes the same listing as the price series it is about to adjust; 33 of the first 45 securities ingested did not.';

do $$
declare
  removed bigint;
begin
  if exists (select 1 from market.one_shot where key = '68-drop-unattributable-corporate-actions') then
    return;
  end if;

  -- Written before `observed_symbol` existed, so which listing each came from is unknowable.
  delete from market.security_corporate_action where observed_symbol is null;
  get diagnostics removed = row_count;

  insert into market.one_shot (key, reason) values
    ('68-drop-unattributable-corporate-actions',
     format('Deleted %s corporate-action rows written before observed_symbol existed. The resource '
            || 'asks Tiingo by US ticker while prices are stored for the primary listing, and those '
            || 'differed for 33 of the first 45 securities — a USD dividend recorded against a KRW '
            || 'price series. Re-earned by the restricted backlog.', removed));
end $$;

alter table market.security_corporate_action
  alter column observed_symbol set not null;

-- ── the backlog now guarantees the listings agree ────────────────────────────
drop view if exists market.pending_corporate_actions;
create view market.pending_corporate_actions as
select
  s.security_id,
  t.value as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
-- THE CONSTRAINT THAT MAKES THE DATA USABLE: only securities whose priced symbol IS the US ticker.
-- `security_symbol` is what `security_price` and `market.performance` are keyed on, so requiring
-- equality here is requiring that the action and the series describe one listing.
join market.security_symbol sym
  on sym.security_id = s.security_id and upper(sym.symbol) = upper(t.value)
left join market.fund_holding_current h
  on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and (s.corporate_actions_missing_at is null
       or s.corporate_actions_missing_at < now() - interval '30 days')
  and not exists (
    select 1 from market.security_corporate_action a
     where a.security_id = s.security_id
       and a.as_of > now() - interval '30 days'
  )
group by s.security_id, t.value
order by best_weight desc;

grant select on market.pending_corporate_actions to service_role;

notify pgrst, 'reload schema';
