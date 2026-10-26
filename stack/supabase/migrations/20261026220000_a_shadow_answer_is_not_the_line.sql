-- A SHADOW ANSWER IS NOT THE LINE: every `not_equity` probe recorded so far is withdrawn, once.
--
-- WHY. The second live wave (2026-10-26 22:09, muffin-ingest run 0ac5dc8b) asked 4by4 Inc, a
-- KOSDAQ company, as `389140.KS`. Yahoo did not answer "unknown": it answered with a SHADOW of the
-- right line, the same company on exchange KOE typed `MUTUALFUND`, so the probe stopped there and
-- recorded `not_equity`, keeping the company out of waves for 90 days. `389140.KQ` is `EQUITY`.
-- Measured the same evening over 30 Korean candidates asked under both suffixes: the wrong one was
-- `absent` 12 times and a `MUTUALFUND` shadow 18 times, in both directions; the right one was
-- `EQUITY` every time.
--
-- THE FIX is in muffin-ingest: the probe moves to the next spelling on `not_equity` as well as on
-- `absent`, and records `not_equity` only once every spelling has been asked. A row recorded before
-- it was asked under one spelling, so it says nothing. Measured before writing this: exactly one
-- such row (4by4), and a `not_equity` from a single-suffix country costs only one more request
-- next week if it is deleted with it.
--
-- Data only: no definition changes, so the schemas/ bundle is unchanged.

delete from market.promotion_probe where outcome = 'not_equity';
