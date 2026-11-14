#!/usr/bin/env bash
# replay.sh's migrations job, then each /mut/<m>.sql copied OVER $NEW in a writable copy of the repo
# before $TEST runs there: for a test that reads the migration file with \i.
set -uo pipefail
C=claude-replay-pg
docker rm -fv $C >/dev/null 2>&1 || true
rm -rf /tmp/claude-replay/repomut && cp -r /tmp/claude-replay/repo /tmp/claude-replay/repomut && chmod -R a+rwX /tmp/claude-replay/repomut
docker run -d --name $C -e POSTGRES_PASSWORD=postgres -v /tmp/claude-replay/repo:/repo:ro -v /tmp/claude-replay/repomut:/repomut -v /tmp/claude-replay/mut:/mut:ro postgres:17-alpine >/dev/null
for i in $(seq 1 60); do
  docker exec -e PGPASSWORD=postgres $C psql -h localhost -U postgres -q -c "create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;" >/dev/null 2>&1 && break
  sleep 1
done
X() { docker exec -e PGPASSWORD=postgres -w /repo $C sh -c "$1" < /dev/null; }
XM() { docker exec -e PGPASSWORD=postgres -w /repomut $C sh -c "$1" < /dev/null; }
X 'for pass in 1 2; do for f in $(ls stack/supabase/migrations-legacy/*.sql | sort); do psql -h localhost -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f "$f" > /tmp/o 2>&1 || { echo "LEGACY FAIL $f"; grep -m1 ERROR /tmp/o; exit 1; }; done; done; echo "ok legacy, twice"' || exit 1
X 'for f in $(ls stack/supabase/migrations/*.sql | grep -v _baseline.sql | sort); do psql -h localhost -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f "$f" > /tmp/o 2>&1 || { echo "MIGRATION FAIL $f"; cat /tmp/o; exit 1; }; done; echo "ok migrations since the baseline"' || exit 1
X 'apk add --no-cache python3 >/dev/null 2>&1; python3 .github/scripts/extract_repeatable.py --dsn postgresql://postgres@localhost:5432/postgres --out /tmp/extracted > /tmp/x 2>&1 || { cat /tmp/x; exit 1; }; if diff -ru stack/supabase/schemas /tmp/extracted > /tmp/bundle.diff; then echo "ok bundle matches the migrations ($(ls /tmp/extracted | wc -l) objects)"; else echo "BUNDLE DIFFERS"; grep "^+++" /tmp/bundle.diff | head; fi'
X 'pass=0; fail=0; for t in stack/supabase/tests/*.sql; do if psql -h localhost -U postgres -q -v ON_ERROR_STOP=1 -f "$t" > /tmp/t 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "TEST FAIL $(basename $t): $(grep -m1 -E "ERROR|EXCEPTION" /tmp/t)"; fi; done; echo "tests: $pass passed, $fail failed"'
X "psql -h localhost -U postgres -q -v ON_ERROR_STOP=1 -f $TEST 2>&1 | sed -n 's/.*NOTICE: *//p'"
for f in $(ls /tmp/claude-replay/mut/*.sql 2>/dev/null); do
  m=$(basename $f .sql)
  XM "cp /mut/$m.sql $NEW"
  sig=$(XM "md5sum $NEW | cut -c1-8")
  if XM "psql -h localhost -U postgres -q -v ON_ERROR_STOP=1 -f $TEST > /tmp/t 2>&1"; then echo "MISSED  $m ($sig)"; else echo "CAUGHT  $m ($sig): $(XM 'grep -m1 -E "ERROR|EXCEPTION" /tmp/t' | cut -c1-220)"; fi
  XM "cp /repo/$NEW $NEW"
done
sig=$(XM "md5sum $NEW | cut -c1-8")
XM "psql -h localhost -U postgres -q -v ON_ERROR_STOP=1 -f $TEST > /tmp/t 2>&1 && echo \"ok the guard passes again after restoring ($sig)\" || echo 'RESTORE FAILED'"
docker rm -fv $C >/dev/null
