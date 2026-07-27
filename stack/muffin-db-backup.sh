#!/usr/bin/env bash
# Nightly logical backup of supabase-db -> OCI Object Storage (S3-compatible).
#
# Rendered onto the node by Ansible (muffin_stack.yml). Dumps the cluster ROLES
# plus the `postgres` database (which holds Supabase auth + storage metadata, the
# app tables, and LangGraph's thread/run/store history), and uploads a gzipped
# SQL file. Retention (30 days) is pruned here (the bucket has no OCI lifecycle
# policy — that needs a tenancy IAM grant).
#
# By default the LangGraph checkpoint tables (`public.checkpoint*`) are excluded
# from the dump DATA. Their SCHEMA is always kept, so a restored DB has empty
# checkpoint tables that LangGraph repopulates. This keeps the dump small and the
# node calm (a full 2GB gzip -9 once starved the services and severed the
# deploy). The whole pipeline is niced and gzip is level 6.
#
# ⚠ WHETHER TO EXCLUDE THEM IS NOW A REAL DECISION (2026-07-27), controlled by
# `db_backups_include_checkpoints` in config.yml (default: false = excluded).
#
# The original justification is dead: checkpoints were "the checkpointer's
# in-flight state (regenerable, not DR-critical)". They are neither. muffin-ui
# reconstructs a past run's EXECUTION TREE — every sub-agent, transcript and tool
# call — from checkpoint history (`lib/agent/run-history.ts`), and the capture
# channels that used to duplicate that into `thread.values` were DELETED
# (muffin-agent #132). With them excluded, a restore yields threads with their
# headline result (`thread.values` survives) but NO record of how a run got there.
#
# The size figure that motivated the exclusion is also misleading: measured on
# the node, 1763 MB of the 1878 MB belongs to a SINGLE errored council thread
# (019f8476, 2026-07-21), and 95% of all blob bytes are the `messages` channel —
# not, as previously assumed, the capture channels (`subagent_runs` is 350 kB).
#
# Recommended order: run `muffin-prune-thread.sh 019f8476-...` (which takes the
# tables to ~115 MB), verify a backup still completes comfortably, THEN set
# `db_backups_include_checkpoints: true`. pg_dump only writes LIVE rows, so the
# dump shrinks the moment the thread is deleted — no VACUUM FULL needed for this.
#
# Restore: see README "Database backups".
set -euo pipefail

BUCKET="{{ db_backups_bucket | default('muffin-db-backups') }}"
ENDPOINT="{{ db_backups_s3_endpoint }}"
ENV_FILE="/etc/muffin/backup.env"
TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
NAME="supabase-db-${TS}.sql.gz"
OUT="/tmp/${NAME}"

log() { echo "$(date -u +%FT%TZ) muffin-db-backup: $*"; }

# Reclaim any dump left behind by an interrupted run.
rm -f /tmp/supabase-db-*.sql.gz

cid="$(docker ps -qf name=muffin_supabase-db | head -1)"
if [ -z "$cid" ]; then log "ERROR: supabase-db container not found"; exit 1; fi

# Roles (tiny) + the postgres DB. LangGraph checkpoint DATA is included only when
# `db_backups_include_checkpoints` is set — see the header for the trade-off.
# PGPASSWORD is already set inside the container. nice/ionice + gzip -6 keep this
# from starving the co-located services on the single node.
# --clean --if-exists makes the dump self-cleaning: on restore it DROPs existing
# objects before recreating them, so it overwrites the stub auth/storage objects
# the supabase/postgres image pre-creates (whose columns lag GoTrue's real
# schema) — without it, auth.users etc. fail to restore. Restore AS supabase_admin
# (the image superuser; plain `postgres` is locked down). See README.
{% if db_backups_include_checkpoints | default(false) %}
# checkpoints INCLUDED — a restore keeps every run's execution tree.
EXCLUDE=""
{% else %}
# The single quotes matter: they are passed THROUGH to the inner shell so the
# `*` is never pathname-expanded there. `$EXCLUDE` is deliberately expanded by
# THIS shell (not escaped) — it is a local, not an exported variable, so the
# inner `bash -c` could not see it.
EXCLUDE="--exclude-table-data='public.checkpoint*'"
{% endif %}

nice -n 19 ionice -c 3 bash -c "
  { docker exec '$cid' pg_dumpall -U postgres --roles-only
    docker exec '$cid' pg_dump -U postgres -d postgres --clean --if-exists $EXCLUDE
  } | gzip -6 > '$OUT'
"
log "dumped $(du -h "$OUT" | cut -f1) -> ${OUT}"

# aws-cli is multi-arch (arm64 OK). Creds + the OCI-S3 checksum workarounds come
# from the env file. --only-show-errors keeps cron mail quiet on success.
aws() { docker run --rm --env-file "$ENV_FILE" -v /tmp:/data amazon/aws-cli:latest "$@" --endpoint-url "$ENDPOINT"; }

aws s3 cp "/data/${NAME}" "s3://${BUCKET}/supabase-db/${NAME}" --only-show-errors
log "uploaded s3://${BUCKET}/supabase-db/${NAME}"

rm -f "$OUT"

# Retention: delete backups older than RETAIN_DAYS (no OCI lifecycle policy —
# that needs a tenancy IAM grant). Tolerant so a prune hiccup never fails the
# (already-succeeded) backup. `aws s3 ls` prints "<date> <time> <size> <key>".
RETAIN_DAYS=30
cutoff="$(date -u -d "${RETAIN_DAYS} days ago" +%Y-%m-%d)"
old="$(aws s3 ls "s3://${BUCKET}/supabase-db/" 2>/dev/null | awk -v c="$cutoff" '$1 < c {print $4}')" || true
for key in $old; do
  [ -n "$key" ] || continue
  aws s3 rm "s3://${BUCKET}/supabase-db/${key}" --only-show-errors && log "pruned ${key}"
done
