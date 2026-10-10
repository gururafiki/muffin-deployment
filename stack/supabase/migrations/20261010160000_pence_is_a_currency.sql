-- PENCE IS A QUOTE CURRENCY, SO IT IS A ROW.
--
-- WHY. London quotes in pence. Yahoo's chart labels VOD.L and SHEL.L `GBp`, and since 2026-10-10
-- the price lane labels each bar with the currency Yahoo states (muffin-ingest `facets.price_chart`,
-- umbrella docs/specs/2026-10-06-the-price-lane-reads-the-quote-currency.md). Every currency column
-- references `market.currency`, and that table held agorot (`ILA`), cents (`ZAC`) and fils (`KWF`)
-- but no pence, so until this row exists the lane leaves London's bars unlabelled rather than fail
-- the foreign key. Until then those bars were labelled `GBP` or `EUR`: a hundred times the price,
-- or not even the right currency.
--
-- `GBX` is the code the market uses for pence. Its exchange rates are DERIVED, not quoted: the FX
-- lane computes them from the pound's in the same pass (`fx.SUBUNITS["GBX"] = ("GBP", 100.0)`), and
-- only for a subunit this table holds. After this deploys, re-run `fx_rate_history` for the `GBP`
-- partition (stage 2 only, no provider call) to give pence the pound's ten years of history.
--
-- ONCE, AS A MIGRATION: `do nothing`, so a row the runtime has already learned is left as it is.

insert into market.currency (code, name)
values ('GBX', 'Pound sterling, in pence')
on conflict (code) do nothing;
