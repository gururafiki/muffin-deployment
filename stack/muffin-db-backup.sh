#!/usr/bin/env bash
# Nightly logical backup of supabase-db -> OCI Object Storage (S3-compatible).
#
# Rendered onto the node by Ansible (muffin_stack.yml). Runs `pg_dumpall` inside
# the supabase-db container (whole cluster: roles + all databases — required to
# restore self-hosted Supabase, whose roles/schemas must exist), gzips it, and
# uploads it via a throwaway aws-cli container using the S3 Customer Secret Keys
# in /etc/muffin/backup.env. Retention is the bucket's OCI lifecycle policy
# (terraform/backups.tf), so there is no pruning here.
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

cid="$(docker ps -qf name=muffin_supabase-db | head -1)"
if [ -z "$cid" ]; then log "ERROR: supabase-db container not found"; exit 1; fi

# PGPASSWORD is already set inside the supabase-db container.
docker exec "$cid" pg_dumpall -U postgres | gzip -9 > "$OUT"
log "dumped $(du -h "$OUT" | cut -f1) -> ${OUT}"

# aws-cli is multi-arch (arm64 OK). Creds + the OCI-S3 checksum workarounds come
# from the env file. --only-show-errors keeps cron mail quiet on success.
aws() { docker run --rm --env-file "$ENV_FILE" -v /tmp:/data amazon/aws-cli:latest "$@" --endpoint-url "$ENDPOINT"; }

aws s3 cp "/data/${NAME}" "s3://${BUCKET}/supabase-db/${NAME}" --only-show-errors
log "uploaded s3://${BUCKET}/supabase-db/${NAME}"

rm -f "$OUT"

# Retention: delete backups older than RETAIN_DAYS. The bucket has no OCI
# lifecycle policy (that needs a tenancy IAM grant), so prune here. `aws s3 ls`
# prints "<date> <time> <size> <key>"; keep it tolerant so a prune hiccup never
# fails the (already-succeeded) backup.
RETAIN_DAYS=30
cutoff="$(date -u -d "${RETAIN_DAYS} days ago" +%Y-%m-%d)"
old="$(aws s3 ls "s3://${BUCKET}/supabase-db/" 2>/dev/null | awk -v c="$cutoff" '$1 < c {print $4}')" || true
for key in $old; do
  [ -n "$key" ] || continue
  aws s3 rm "s3://${BUCKET}/supabase-db/${key}" --only-show-errors && log "pruned ${key}"
done
