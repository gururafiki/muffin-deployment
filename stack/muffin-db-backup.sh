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
docker run --rm --env-file "$ENV_FILE" -v /tmp:/data amazon/aws-cli:latest \
  s3 cp "/data/${NAME}" "s3://${BUCKET}/supabase-db/${NAME}" \
  --endpoint-url "$ENDPOINT" --only-show-errors
log "uploaded s3://${BUCKET}/supabase-db/${NAME}"

rm -f "$OUT"
