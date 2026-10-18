---
name: muffin-schema-change
description:
  Use when changing a view, function or table in muffin-deployment's market schema — writing the
  migration, regenerating the schemas/ bundle, proving the guard test by mutation, validating the
  new definition against production's rows in a rolled-back transaction, and re-measuring anon
  latency after the deploy. Also the way to replay quality.yml's migrations job on the node when
  Docker here is wedged.
---

# Change the market schema

Done this way four times on 2026-10-17 (muffin-deployment#437, #439, #440, #441) and once on
2026-10-18 (#443). Each step below caught something the step before it could not.

## 1. The migration

`stack/supabase/migrations/<yyyymmddhhmmss>_<a_sentence_saying_what_is_now_true>.sql`.

- **Start from the CURRENT definition**, which is `stack/supabase/schemas/<nnnn>-<object>.sql`
  (the last definer wins), never from the migration that introduced the object.
- **The header says why, with numbers measured on production**, then the fix and its guard.
- **`create or replace` keeps the grants only while the columns stay the same or are appended.** A
  function keeps its ACL always (so a grant in a re-run can only add). A view whose columns change
  must be dropped, which loses its ACL: re-issue the grants from `relacl`, never from a list.
- **A data repair runs once:** post-baseline migrations are applied by version. Re-queue work
  explicitly (for example, delete the affected `ttm_derivation` rows) rather than relying on a
  backlog view to notice.

## 2. The guard test

`stack/supabase/tests/<a-sentence>.sql`, inside `begin; … rollback;`, raising with a message that
names the defect.

- **The fixture must make the candidate rules disagree.** Give the two sources different values, put
  the high-priority source's date before the other in one period and after it in another, and add
  the tie case. A fixture where the right rule and the wrong one give the same answer certifies
  nothing.
- **Assert a floor as well as the rule.** For example, "the read touched at least the target's own
  rows", so a walk that finds nothing cannot pass.
- **When timing cannot fail on a fixture, count the work.** Sum `Actual Rows × Loops` over the
  relation's nodes in `EXPLAIN (ANALYZE, FORMAT JSON)` (strict `$.**`). Sort the target's id last, so
  no plan can stop early and look narrow.
- **After inserting securities, `refresh materialized view market.symbol_security`.** `now()` is
  transaction time.

## 3. Replay on the node, with mutations

Local Docker has been wedged since 2026-10-04, so the replay runs on the node. It builds
`postgres:17-alpine` the way `quality.yml` does: legacy migrations twice, the migrations after the
baseline, extract the bundle and diff it, apply the bundle and re-extract, then every test. Then,
for each `/mut/*.sql`: apply it, print `SIG`, run `TEST` (it must be CAUGHT), and restore with `NEW`.

```bash
D=/tmp/claude-replay
timeout 60 ssh muffin "rm -rf $D && mkdir -p $D/repo/stack $D/repo/.github $D/mut"   # one level only
timeout 120 rsync -a --delete stack/supabase/ muffin:$D/repo/stack/supabase/
timeout 60 rsync -a .github/scripts/ muffin:$D/repo/.github/scripts/
timeout 60 rsync -a <dir of mutated copies of the migration>/ muffin:$D/mut/
{ echo "TEST=stack/supabase/tests/<test>.sql"
  echo "NEW=stack/supabase/migrations/<migration>.sql"
  echo "SIG=\"select md5(pg_get_viewdef('market.<view>'::regclass))\""   # or pg_get_functiondef
  cat .agents/skills/muffin-schema-change/scripts/replay.sh
} | timeout 1500 ssh -o ServerAliveInterval=30 muffin 'bash -s' 2>&1 \
  | grep -E '^ok|^tests|CAUGHT|MISSED|FAIL|DIFFERS|CHANGED'
```

The replay takes 10-20 minutes with mutations, so run it in the background. **The `timeout` and
the keepalive are what make it fail rather than hang** if this machine sleeps: without them, a
replay and a rolled-back production check sat for five hours on 2026-10-18 with nothing running on
the node.

- **The first pass reports `BUNDLE DIFFERS`, and your test fails inside the full test loop.** The
  bundle step re-applied the stale `schemas/` file. Copy the regenerated file and run again:
  `scp muffin:$D/extracted/<nnnn>-<object>.sql stack/supabase/schemas/`. On the second pass,
  "bundle matches", "applying the bundle changes nothing" and every test passing are all required.
- **Every mutation must be CAUGHT with a different `SIG`.** An identical SIG means the mutation never
  applied, and its "caught" proves nothing. Make the mutations realistic: the old definition, the
  rule half-applied, the tie broken the other way.

## 4. Validate on production's rows, rolled back

Install the new definition under a temporary name inside `begin; … rollback;`:
- a view as `create temporary view x_new as <definition>`;
- a function as `market.<name>_check`.

Then:
- **Compare row for row with the live object** for real symbols, AAPL, MSFT, 005930.KS, SAP.DE,
  7203.T, VOD.L and NVDA among them, using `except all` both ways. **Read the rows that changed,
  never the count.** This found the IFRS opening balances SEC dates the day after a year end, which
  no fixture had.
- **Time the app's own reads** (the probes in `.github/scripts/check_anon_read_latency.py`), best of
  3, old against new. Pair each timing with its own statement: a parser that took the row counts
  for times reported identical figures.
- **A read-only session cannot create a temporary table.** Use a `materialized` CTE.

## 5. Ship and re-measure

PR → the 11 checks (compare with a known-good PR) → merge → `deploy.yml`.

After the deploy:
- confirm `supabase_migrations.schema_migrations` lists the new version;
- confirm `docker inspect … State.StartedAt` on the three Dagster services is unchanged
  (`muffin-deploy`);
- once `pgrep -fc '[m]uffin-db-backup.sh'` reads 0, run
  `BASE=https://supabase.<domain> ANON=<anon key> python3 .github/scripts/check_anon_read_latency.py`;
- read the served rows for the cases that motivated the change.

## Traps, each met on 2026-10-17 or 10-18

| Symptom | Cause |
|---|---|
| The first file of the legacy set fails at random | The image's init runs a temporary server on the socket. Wait on `psql -h localhost`, which only the real server answers |
| `rsync: mkdir … failed` | rsync creates only the last path component |
| The rest of a script silently vanishes | `docker exec -i` inside `ssh … 'bash -s'` eats the script's stdin; use `< /dev/null` where the SQL is in `-c` |
| `zsh: =====: not found` | zsh expands a word starting with `=`; never `echo =====` |
| `set -- $q` loops over one word | zsh does not word-split; use a function |
| A remote command prints nothing for hours, and the node runs nothing | this machine slept and the ssh connection died silently; `timeout` plus `-o ServerAliveInterval=30` |
| `\gset` stops the script with no row printed | an unnamed column (`?column?`) is not a variable name; alias every column it sets |
| A before/after read of a serving view times out in the rolled-back check | a join from a temp table cannot carry the symbol filter into the view's window; read each symbol with a constant |
| A diff shows no `diff` header lines | busybox `diff` prints none; grep `+++` |
| `unterminated quoted string` in psql | an apostrophe in an `\echo` |
