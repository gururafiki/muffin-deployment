#!/usr/bin/env bash
# Delete ONE LangGraph thread and all of its checkpoint data. Operator tool —
# rendered onto the node by Ansible, never run by cron.
#
# Why this exists: checkpoint storage on this node is dominated by single bad
# threads, not by general growth. Measured 2026-07-27: `checkpoint_blobs` was
# 1878 MB, of which **1763 MB belonged to one errored council thread**
# (019f8476-06fd-70bd-97a8-011c7f2bc4d9). Deleting it takes the tables to
# ~115 MB, which is what makes `db_backups_include_checkpoints: true` cheap.
#
# ⚠ THIS IS IRREVERSIBLE AND IT DESTROYS RUN HISTORY. Checkpoints are the only
# record of what a run did (muffin-ui reconstructs the execution tree from
# them), so deleting a thread deletes its transcripts, tool calls and sub-agent
# tree permanently. `thread.values` goes too — the thread disappears from Calls.
# Take a backup first; there is no undo.
#
# Usage (on the node):
#   muffin-prune-thread.sh <thread-uuid>          # inspect only, changes nothing
#   muffin-prune-thread.sh <thread-uuid> --yes    # actually delete
#
# On disk vs in backups: `pg_dump` only writes LIVE rows, so the nightly dump
# shrinks as soon as the rows are gone — no VACUUM needed for that. The on-disk
# FILES do not shrink without `VACUUM FULL`, which takes an ACCESS EXCLUSIVE
# lock and needs free space equal to the table. Do not run it casually on this
# node; plain autovacuum will reuse the freed space for new checkpoints.
set -euo pipefail

THREAD_ID="${1:-}"
CONFIRM="${2:-}"

if [ -z "$THREAD_ID" ]; then
  echo "usage: $(basename "$0") <thread-uuid> [--yes]" >&2
  exit 2
fi
if ! [[ "$THREAD_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "ERROR: '$THREAD_ID' is not a UUID" >&2
  exit 2
fi

cid="$(docker ps -qf name=muffin_supabase-db | head -1)"
if [ -z "$cid" ]; then echo "ERROR: supabase-db container not found" >&2; exit 1; fi

# TWO helpers on purpose. `docker exec -i` forwards stdin to the container, so a
# query call made with -i silently EATS whatever is on this script's stdin — when
# run over `ssh <<heredoc` that is the rest of the script itself, and everything
# after the first query vanishes without an error. Queries therefore get no -i;
# only the piped transaction does.
psql() { docker exec "$cid" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@" </dev/null; }
psql_stdin() { docker exec -i "$cid" psql -U postgres -d postgres -v ON_ERROR_STOP=1; }

# Deletion order: children before parents, so no delete trips a foreign key.
# The actual set of tables is DISCOVERED below rather than assumed — this list
# only fixes the ORDER, and anything discovered that is not named here aborts
# the run. That way a schema change (a renamed table, a new thread-scoped one)
# fails loudly here instead of silently leaving rows behind.
# `cron` and `thread_ttl` were discovered by the schema check on the deployed
# node — both reference a thread, so both must go before `thread` itself. A cron
# row means a SCHEDULE is attached to this thread; the dry run prints the counts,
# so check them before deleting a thread you did not expect to be scheduled.
KNOWN_TABLES=(
  checkpoint_delete_queue
  checkpoint_writes
  checkpoint_blobs
  checkpoints
  cron
  thread_ttl
  run
  thread
)

echo "== schema check =="
present="$(psql -tAc "
  SELECT string_agg(DISTINCT table_name, ' ' ORDER BY table_name)
  FROM information_schema.columns
  WHERE table_schema = 'public' AND column_name = 'thread_id'
")"
echo "  thread-scoped tables found: ${present:-<none>}"
for t in $present; do
  case " ${KNOWN_TABLES[*]} " in
    *" $t "*) ;;
    *)
      echo "ERROR: unrecognised thread-scoped table '$t'." >&2
      echo "       Add it to KNOWN_TABLES (in delete order) before pruning," >&2
      echo "       or its rows would be orphaned." >&2
      exit 1 ;;
  esac
done

# Delete only from tables that actually exist, in the safe order.
TARGETS=()
for t in "${KNOWN_TABLES[@]}"; do
  case " $present " in *" $t "*) TARGETS+=("$t") ;; esac
done
if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "ERROR: no thread-scoped tables found — wrong database?" >&2
  exit 1
fi
echo "  will delete from: ${TARGETS[*]}"

echo
echo "== thread $THREAD_ID =="
psql -c "
  SELECT thread_id, created_at, status, metadata->>'graph_id' AS graph_id
  FROM thread WHERE thread_id = '$THREAD_ID';
"

echo "== what would be deleted =="
for t in "${TARGETS[@]}"; do
  n="$(psql -tAc "SELECT count(*) FROM \"$t\" WHERE thread_id = '$THREAD_ID'")"
  printf '  %-20s %s row(s)\n' "$t" "$n"
done
psql -c "
  SELECT pg_size_pretty(coalesce(sum(pg_column_size(blob)), 0)) AS blob_bytes_freed
  FROM checkpoint_blobs WHERE thread_id = '$THREAD_ID';
"

if [ "$CONFIRM" != "--yes" ]; then
  echo
  echo "DRY RUN — nothing was changed. Re-run with --yes to delete."
  exit 0
fi

echo
echo "== deleting (single transaction) =="
{
  echo "BEGIN;"
  for t in "${TARGETS[@]}"; do
    echo "DELETE FROM \"$t\" WHERE thread_id = '$THREAD_ID';"
  done
  echo "COMMIT;"
} | psql_stdin

echo
echo "== after =="
psql -c "
  SELECT pg_size_pretty(pg_total_relation_size('checkpoint_blobs')) AS blobs_on_disk,
         (SELECT count(*) FROM checkpoints WHERE thread_id = '$THREAD_ID') AS leftover_rows;
"
for t in "${TARGETS[@]}"; do
  n="$(psql -tAc "SELECT count(*) FROM \"$t\" WHERE thread_id = '$THREAD_ID'")"
  [ "$n" = "0" ] || echo "  WARNING: $t still has $n row(s) for this thread"
done
echo
echo "Done. The next nightly dump is already smaller (pg_dump writes live rows only)."
echo "On-disk files stay the same size until autovacuum reuses the space, which is"
echo "fine — VACUUM FULL would lock the table and is not needed for the backup goal."
