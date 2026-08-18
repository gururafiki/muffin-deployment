-- Debt terms are written by whichever fund's ingest runs, and funds file at different quarter-ends.
--
-- WHY THIS IS A TEST AND NOT A COMMENT. AGG, LQD, HYG, TIP and EMB all hold overlapping corporate
-- bonds, and `fund-holdings` ingests them in whatever order the backlog offers. Without an ordering
-- rule the stored coupon and maturity would be whichever fund ran LAST — so the same bond's terms
-- would flap between filings on every pass, with nothing erroring and nothing to notice. A
-- floating-rate note's `annualizedRt` genuinely changes between filings, which is exactly what
-- makes "newest filing wins" the right rule rather than "first writer wins".
--
-- The three cases below are the whole contract: newer wins, older is refused, and equal is allowed
-- (a re-ingest of the same filing must be idempotent rather than refused).

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('bond', 'Bond') on conflict do nothing;
insert into market.coupon_kind (code, name) values ('Fixed', 'Fixed') on conflict do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000007101', 'T71 Corporate bond', 'bond')
on conflict (security_id) do nothing;

-- 1. A first write lands.
select market.set_debt_terms('[{
  "security_id": "00000000-0000-0000-0000-000000007101",
  "maturity_date": "2029-04-15", "coupon_rate": 4.2,
  "coupon_kind_code": "Fixed", "in_default": false, "as_of": "2026-03-31"
}]'::jsonb);

do $$
declare r numeric; m date;
begin
  select coupon_rate, maturity_date into r, m
    from market.security where security_id = '00000000-0000-0000-0000-000000007101';
  if r is distinct from 4.2 or m is distinct from date '2029-04-15' then
    raise exception 'the first write did not land: rate=%, maturity=%', r, m;
  end if;
end $$;

-- 2. A NEWER filing overwrites — a floating note's rate really does change.
select market.set_debt_terms('[{
  "security_id": "00000000-0000-0000-0000-000000007101",
  "maturity_date": "2029-04-15", "coupon_rate": 4.9,
  "coupon_kind_code": "Fixed", "in_default": false, "as_of": "2026-06-30"
}]'::jsonb);

do $$
declare r numeric;
begin
  select coupon_rate into r
    from market.security where security_id = '00000000-0000-0000-0000-000000007101';
  if r is distinct from 4.9 then
    raise exception 'a newer filing was refused: rate is % (expected 4.9)', r;
  end if;
end $$;

-- 3. An OLDER filing is refused. This is the case that would otherwise make the value flap.
select market.set_debt_terms('[{
  "security_id": "00000000-0000-0000-0000-000000007101",
  "maturity_date": "2029-04-15", "coupon_rate": 1.1,
  "coupon_kind_code": "Fixed", "in_default": false, "as_of": "2026-01-31"
}]'::jsonb);

do $$
declare r numeric;
begin
  select coupon_rate into r
    from market.security where security_id = '00000000-0000-0000-0000-000000007101';
  if r is distinct from 4.9 then
    raise exception 'an OLDER filing overwrote a newer one: rate is % (expected 4.9)', r;
  end if;
end $$;

-- 4. The SAME filing re-applied is allowed. `fund-holdings` re-runs, and a re-ingest that silently
--    refused itself would look identical to one that worked.
select market.set_debt_terms('[{
  "security_id": "00000000-0000-0000-0000-000000007101",
  "maturity_date": "2029-04-15", "coupon_rate": 5.5,
  "coupon_kind_code": "Fixed", "in_default": false, "as_of": "2026-06-30"
}]'::jsonb);

do $$
declare r numeric;
begin
  select coupon_rate into r
    from market.security where security_id = '00000000-0000-0000-0000-000000007101';
  if r is distinct from 5.5 then
    raise exception 're-applying the same filing was refused: rate is % (expected 5.5)', r;
  end if;
end $$;

-- 5. A ZERO COUPON MUST SURVIVE THE ROUND TRIP. Measured range on AGG is 0.0 to 11.5, so zero is a
--    real zero-coupon bond. Anything treating it as missing — in the parser, the payload or the
--    SQL — turns those bonds into "rate unknown".
select market.set_debt_terms('[{
  "security_id": "00000000-0000-0000-0000-000000007101",
  "maturity_date": "2031-01-01", "coupon_rate": 0,
  "coupon_kind_code": "Fixed", "in_default": false, "as_of": "2026-09-30"
}]'::jsonb);

do $$
declare r numeric;
begin
  select coupon_rate into r
    from market.security where security_id = '00000000-0000-0000-0000-000000007101';
  if r is null then
    raise exception 'a 0.0 coupon was stored as NULL — a zero-coupon bond is not a missing rate';
  end if;
  if r <> 0 then
    raise exception 'a 0.0 coupon was stored as %', r;
  end if;
end $$;

rollback;
