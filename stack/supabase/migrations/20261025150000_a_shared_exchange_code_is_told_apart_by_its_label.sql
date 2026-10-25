-- A SHARED EXCHANGE CODE IS TOLD APART BY ITS LABEL. Decided by the user 2026-10-25 (umbrella
-- docs/deferred/2026-10-04-taiwan-s-tpex-lines-are-filed-under-tt.md, option 1).
--
-- WHY. Taiwan has two stock markets. The Taiwan Stock Exchange is `.TW` on Yahoo and the Taipei
-- Exchange (TPEx) is `.TWO`, but OpenFIGI files both under exchange code `TT`. It does tell them
-- apart, in a label on the code: `TT (Taiwan Stock Exchange)` against `TT (Taipei Stock Exchange)`.
-- `market.exchange` maps `TT` to `.TW` only, so every TPEx line is priced under a spelling Yahoo
-- does not serve. Measured 2026-10-04: 100 of the 101 dead `.TW` symbols carry the Taipei label in
-- the stored OpenFIGI answer; on 2026-10-25 the `TT.common` directory pages hold 1,424 Taipei lines,
-- 1,090 Taiwan lines and 5 with no label.
--
-- WHAT. A control table naming the suffix a labelled line takes. The symbology ladder (its local
-- pick and its Yahoo home-market test) and the directory's stage 2 read a labelled match before
-- falling back to `market.exchange` (muffin-ingest). Both re-derive from raw already on disk.
-- One row today; another shared code is another row, not a change of key (the MIC re-key was
-- option 2, deferred until a second one appears).
--
-- Guard: tests/a-shared-exchange-code-is-told-apart-by-its-label.sql.

create table if not exists market.exchange_label (
  exch_code text not null references market.exchange (exch_code),
  label     text not null,
  suffix    text not null,
  reason    text not null,
  primary key (exch_code, label),
  -- A label is matched as OpenFIGI spells it inside the parentheses, so it carries none itself.
  constraint exchange_label_label_shape check (label !~ '[()]' and label = btrim(label)),
  constraint exchange_label_suffix_shape check (suffix ~ '^\.[A-Z]+$')
);

comment on table market.exchange_label is
  'An OpenFIGI exchange code that covers two markets, told apart by the label OpenFIGI puts on it '
  '(`TT (Taipei Stock Exchange)`): the suffix that labelled line takes. Read by the symbology ladder '
  'and the venue directory before market.exchange. Decided 2026-10-25 (TPEx).';

-- CONDITIONAL ON THE VENUE, as directory_alias is: a rebuilt database without `TT` gets no row
-- rather than a foreign-key failure.
insert into market.exchange_label (exch_code, label, suffix, reason)
select 'TT', 'Taipei Stock Exchange', '.TWO',
       'TPEx (MIC ROCO), Yahoo `.TWO`. OpenFIGI files it under TT with the Taiwan Stock Exchange '
       '(`.TW`); 100 of the 101 dead `.TW` symbols on 2026-10-04 were Taipei-labelled lines.'
 where exists (select 1 from market.exchange where exch_code = 'TT')
on conflict (exch_code, label) do update set suffix = excluded.suffix, reason = excluded.reason;

grant select, insert, update, delete on market.exchange_label to service_role;
grant select on market.exchange_label to ingest_rw, anon, authenticated;
-- `market`'s default privileges still give `ingest_rw` DML on every new table; the worker reads
-- this one and must not be able to rewrite its own instructions.
revoke insert, update, delete, truncate on market.exchange_label from ingest_rw;

alter table market.exchange_label enable row level security;
drop policy if exists exchange_label_public_read on market.exchange_label;
create policy exchange_label_public_read on market.exchange_label for select using (true);
