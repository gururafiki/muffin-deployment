-- The exchange sweep must enumerate exchange-traded products, on the RIGHT OpenFIGI field.
--
-- WHY THIS EXISTS AS A TEST. Measured 2026-08-17: 102,390 rows in `exchange_listing`, of which
-- 99,673 Common Stock and 2,717 Depositary Receipts — and **zero funds**, against 74 ETFs in the
-- universe, every one hand-added. Nothing in the system could report that, because every coverage
-- number is computed over `security_type_code = 'equity'` and an absent asset class is not a
-- failing row anywhere. The failure is an ABSENCE, and absences do not raise.
--
-- The subtle half, and the reason this asserts the FIELD and not just the row: OpenFIGI has two
-- type vocabularies and the coarse one is unusable here. Measured against `/v3/filter`:
--
--   securityType2 = 'Mutual Fund'  US -> 44,119  (FEUCX, WATFX, NPRTX — open-end funds)
--   securityType  = 'ETP'          US ->  6,664  (DGP, UWM, EWH, ICLN, MDY — actual ETFs)
--
-- SPY is `securityType: 'ETP'` inside `securityType2: 'Mutual Fund'`. A row added with the default
-- `securityType2` would therefore ask for 44,119 open-end mutual funds, blow the 15,000 paging
-- ceiling, and file none of it under anything an exchange directory should hold — while LOOKING
-- exactly like the ETF sweep it is named after. That is the failure this pins down.

\set ON_ERROR_STOP on

begin;

-- 1. ETP is swept at all.
do $$
declare n integer;
begin
  select count(*) into n from market.exchange_sweep_type where security_type = 'ETP';
  if n <> 1 then
    raise exception 'the sweep does not enumerate ETPs: the directory can never contain a fund';
  end if;
end $$;

-- 2. …on the FINE field. This is the assertion that a plausible-looking wrong row fails.
do $$
declare f text;
begin
  select figi_field into f from market.exchange_sweep_type where security_type = 'ETP';
  if f is distinct from 'securityType' then
    raise exception
      'ETP is swept on %, but its securityType2 bucket is Mutual Fund: 44,119 US rows of open-end funds, over the 15,000 paging ceiling', coalesce(f, '<null>');
  end if;
end $$;

-- 3. …and the stock types are NOT moved onto it. `securityType: 'Common Stock'` is not a valid
--    fine-grained value (the fine vocabulary spells it 'Common Stock' only at level 2), so
--    "fixing" the two existing rows to match ETP would silently empty the main sweep.
do $$
declare bad text;
begin
  select string_agg(security_type, ', ') into bad
    from market.exchange_sweep_type
   where security_type in ('Common Stock', 'Depositary Receipt')
     and figi_field <> 'securityType2';
  if bad is not null then
    raise exception 'these types must filter on securityType2, not the fine field: %', bad;
  end if;
end $$;

-- 4. Every sweep type names a field the function understands. A typo here does not error at the
--    provider — OpenFIGI ignores an unknown key and returns the venue UNFILTERED, which is how
--    "Samsung Electronics" once returned 8,725 rows that were nearly all options.
do $$
declare bad text;
begin
  select string_agg(security_type || '=' || figi_field, ', ') into bad
    from market.exchange_sweep_type
   where figi_field not in ('securityType', 'securityType2');
  if bad is not null then
    raise exception 'unknown OpenFIGI type field (the provider would silently return the venue unfiltered): %', bad;
  end if;
end $$;

rollback;
