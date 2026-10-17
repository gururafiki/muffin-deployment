#!/usr/bin/env bash
# Replays quality.yml's migrations job in a throwaway postgres:17-alpine on the node, then runs $TEST
# against each mutation in /mut. Env: TEST (the guard), NEW (the migration that restores the change),
# SIG (a SQL fingerprint of the changed object, printed per mutation to prove it applied).
# Usage: see ../SKILL.md. Read-only on production: it touches only its own container and directory.
set -uo pipefail
C=claude-replay-pg
docker rm -f $C >/dev/null 2>&1 || true
docker run -d --name $C -e POSTGRES_PASSWORD=postgres -v /tmp/claude-replay/repo:/repo:ro -v /tmp/claude-replay/mut:/mut:ro postgres:17-alpine >/dev/null
for i in $(seq 1 60); do
  docker exec -e PGPASSWORD=postgres $C psql -h localhost -U postgres -q -c "create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;" >/dev/null 2>&1 && break
  sleep 1
done
X() { docker exec -e PGPASSWORD=postgres -w /repo $C sh -c "$1" < /dev/null; }
X 'for pass in 1 2; do for f in $(ls stack/supabase/migrations-legacy/*.sql | sort); do psql -h localhost -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f "$f" > /tmp/o 2>&1 || { echo "LEGACY FAIL $f"; grep -m1 ERROR /tmp/o; exit 1; }; done; done; echo "ok legacy, twice"' || exit 1
X 'for f in $(ls stack/supabase/migrations/*.sql | grep -v _baseline.sql | sort); do psql -h localhost -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f "$f" > /tmp/o 2>&1 || { echo "MIGRATION FAIL $f"; cat /tmp/o; exit 1; }; done; echo "ok migrations since the baseline"' || exit 1
X 'apk add --no-cache python3 >/dev/null 2>&1; python3 .github/scripts/extract_repeatable.py --dsn postgresql://postgres@localhost:5432/postgres --out /tmp/extracted > /tmp/x 2>&1 || { cat /tmp/x; exit 1; }; if diff -ru stack/supabase/schemas /tmp/extracted > /tmp/bundle.diff; then echo "ok bundle matches the migrations ($(ls /tmp/extracted | wc -l) objects)"; else echo "BUNDLE DIFFERS"; fi'
rm -rf /tmp/claude-replay/extracted && docker cp $C:/tmp/extracted /tmp/claude-replay/extracted >/dev/null
X '{ echo "set check_function_bodies = off;"; cat stack/supabase/schemas/*.sql; } | psql -h localhost -U postgres -q --single-transaction -v ON_ERROR_STOP=1 > /tmp/b 2>&1 || { echo "BUNDLE APPLY FAIL"; grep -m1 ERROR /tmp/b; }; python3 .github/scripts/extract_repeatable.py --dsn postgresql://postgres@localhost:5432/postgres --out /tmp/re > /dev/null 2>&1; if diff -ru stack/supabase/schemas /tmp/re > /tmp/after.diff; then echo "ok applying the bundle changes nothing"; else echo "BUNDLE APPLY CHANGED"; fi'
X 'pass=0; fail=0; for t in stack/supabase/tests/*.sql; do if psql -h localhost -U postgres -q -v ON_ERROR_STOP=1 -f "$t" > /tmp/t 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "TEST FAIL $(basename $t): $(grep -m1 -E "ERROR|EXCEPTION" /tmp/t)"; fi; done; echo "tests: $pass passed, $fail failed"'
X "psql -h localhost -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f $NEW > /dev/null"
X "psql -h localhost -U postgres -q -v ON_ERROR_STOP=1 -f $TEST 2>&1 | sed -n 's/.*NOTICE: *//p'"
for f in $(ls /tmp/claude-replay/mut/*.sql 2>/dev/null); do
  m=$(basename $f .sql)
  X "psql -h localhost -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f /mut/$m.sql > /tmp/m 2>&1 || { echo 'MUTATION DID NOT APPLY'; grep -m1 ERROR /tmp/m; }"
  sig=$(X "psql -h localhost -U postgres -tAc \"$SIG\"")
  if X "psql -h localhost -U postgres -q -v ON_ERROR_STOP=1 -f $TEST > /tmp/t 2>&1"; then echo "MISSED  $m ($sig)"; else echo "CAUGHT  $m ($sig): $(X 'grep -m1 -E "ERROR|EXCEPTION" /tmp/t' | cut -c1-200)"; fi
  X "psql -h localhost -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f $NEW > /dev/null"
done
sig=$(X "psql -h localhost -U postgres -tAc \"$SIG\"")
X "psql -h localhost -U postgres -q -v ON_ERROR_STOP=1 -f $TEST > /tmp/t 2>&1 && echo \"ok the guard passes again after restoring ($sig)\" || echo 'RESTORE FAILED'"
docker rm -f $C >/dev/null
