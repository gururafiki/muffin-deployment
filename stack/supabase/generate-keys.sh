#!/bin/sh
# Generate the Supabase self-host secrets for secrets.yaml / GitHub secrets:
#   - SUPABASE_JWT_SECRET  (HS256 signing secret shared by GoTrue/PostgREST/langgraph-api)
#   - SUPABASE_ANON_KEY    (long-lived HS256 JWT, role=anon — the public client key)
#   - SUPABASE_SERVICE_ROLE_KEY (long-lived HS256 JWT, role=service_role — server-side only)
#   - SUPABASE_DB_PASSWORD
#   - SUPABASE_PG_META_CRYPTO_KEY (postgres-meta/Studio encryption key)
#
# Usage: ./generate-keys.sh            (generates a fresh JWT secret)
#        ./generate-keys.sh <secret>   (re-derives the anon/service keys from an existing secret)
set -eu

SECRET="${1:-$(openssl rand -hex 20)}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

sign() { # $1 = role
  now=$(date +%s)
  exp=$((now + 315360000)) # +10 years, matching supabase's own key generator
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$1" "$now" "$exp" | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

echo "supabase_jwt_secret: \"$SECRET\""
echo "supabase_anon_key: \"$(sign anon)\""
echo "supabase_service_role_key: \"$(sign service_role)\""
echo "supabase_db_password: \"$(openssl rand -hex 16)\""
echo "supabase_pg_meta_crypto_key: \"$(openssl rand -hex 16)\""
echo "supabase_secret_key_base: \"$(openssl rand -hex 32)\""
echo "supabase_realtime_db_enc_key: \"$(openssl rand -hex 8)\""
