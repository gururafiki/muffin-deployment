#!/bin/bash
# Run the Supabase CLI against this node's database. ONE definition, called by every task that
# needs it, because the alternative is the same twelve lines of `docker run` in two shell blocks
# that are then free to disagree.
#
# WHY A CONTAINER FOR A BINARY THAT IS INSTALLED ON THE HOST.
# Postgres is NOT published on the host — measured, nothing listens on 5432 — so anything reaching
# `supabase-db` has to be on the `muffin-net` overlay, which is attachable. There is no official CLI
# image to run instead: `supabase/cli` does not exist on Docker Hub (the registry answers 401 for it
# while `library/postgres` answers 200 through the same request), so the released binary is the only
# distribution there is.
#
# WHY debian AND NOT THE DATABASE IMAGE.
# The CLI is DYNAMICALLY LINKED against glibc — `interpreter /lib/ld-linux-aarch64.so.1`. The first
# attempt borrowed `supabase/postgres`, on the assumption that the database image is Debian. It is
# not: it carries `/lib/ld-musl-aarch64.so.1`, so the exec failed with
#
#     exec /usr/local/bin/supabase: no such file or directory
#
# which names the binary that plainly exists and says nothing about the loader that does not. Both
# facts were checked with `ls` inside each image rather than assumed a second time.
set -euo pipefail

IMAGE="${MUFFIN_CLI_IMAGE:-debian:12-slim}"
PW_FILE="${MUFFIN_DB_PW_FILE:-/root/.muffin-db-pw}"
# THE PROJECT ROOT IS THE DIRECTORY THAT *CONTAINS* `supabase/`, NOT THE `supabase/` FOLDER.
# Mounting the folder itself as the working directory makes every command look one level too high:
#
#     glob supabase/migrations/20260910000000_*.sql: file does not exist
#
# so the staged directory is mounted AT `/work/supabase` and the working directory is `/work`.
# Mounted precisely rather than by mounting the parent, which would hand the container everything
# else staged under /home/ubuntu for no reason.
PROJECT="${MUFFIN_SUPABASE_DIR:-/home/ubuntu/supabase}"

pw=$(cat "$PW_FILE")

run() {
  docker run --rm --network muffin-net \
    -v /usr/local/bin/supabase:/usr/local/bin/supabase:ro \
    -v "$PROJECT":/work/supabase -w /work \
    --entrypoint /usr/local/bin/supabase \
    "$IMAGE" "$@"
}

# A PRECONDITION, NOT AN ASSUMPTION: the bind-mounted binary has to run in this image. Checked
# before every invocation because it is the failure that already cost two deploys, and because it
# costs one process to turn a confusing exec error into a named one.
if ! run --version >/dev/null 2>&1; then
  echo "the Supabase CLI cannot execute inside $IMAGE — check the loader it needs against that image" >&2
  exit 1
fi

# REDACTED, NOT HIDDEN. The password can appear in a connection error and this is a public
# repository, so the output is filtered rather than the whole task being censored — hiding it is
# what made the first cutover failure useless.
# `sslmode=disable` IS REQUIRED, and the CLI does not default to it. Without it every command
# fails with `tls error (The server does not support SSL connections)`: this Postgres is not built
# with SSL, and it does not need to be — the connection never leaves the `muffin-net` overlay, which
# is exactly why `postgres-exporter` already carries the same parameter in its own DSN.
run "$@" --db-url "postgresql://postgres:$pw@supabase-db:5432/postgres?sslmode=disable" 2>&1 \
  | sed "s|:$pw@|:REDACTED@|g"
