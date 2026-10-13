#!/usr/bin/env bash
# Generate initial credentials outside Git. Never use this to rotate an existing instance.
set +x
set -Eeuo pipefail
umask 077

NAMESPACE=server
BACKUP_DIR=""
DB_HOST=postgresql-dev-primary.data.svc.cluster.local
SITE_URL=https://infisical.jaystacks.com
APPLY=false

usage() {
  cat <<'USAGE'
Usage: bash scripts/prepare-infisical-secrets.sh --backup-dir /secure/infisical-initial [--apply]
  --backup-dir PATH  New absolute directory outside this Git checkout (parent must exist)
  --namespace NAME   Kubernetes namespace (default: server)
  --db-host HOST     PostgreSQL hostname (default: postgresql-dev-primary.data.svc.cluster.local)
  --site-url URL     External HTTPS URL (default: https://infisical.jaystacks.com)
  --apply            Create the two new Kubernetes Secrets after generating the files
USAGE
}

fail() { printf '%s\n' "$*" >&2; exit 1; }
need_value() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value for $1"; }

while (($#)); do
  case "$1" in
    --backup-dir) need_value "$@"; BACKUP_DIR="$2"; shift 2 ;;
    --namespace) need_value "$@"; NAMESPACE="$2"; shift 2 ;;
    --db-host) need_value "$@"; DB_HOST="$2"; shift 2 ;;
    --site-url) need_value "$@"; SITE_URL="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

for tool in kubectl openssl python3 realpath tr; do
  command -v "$tool" >/dev/null || fail "Missing command: $tool"
done
[[ "$BACKUP_DIR" = /* ]] || fail 'Use an absolute --backup-dir outside Git.'
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#NAMESPACE} -le 63 ]] || fail 'Invalid namespace.'
[[ "$DB_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || fail 'Use a PostgreSQL hostname without a port or URL scheme.'
[[ "$SITE_URL" = https://* ]] || fail 'SITE_URL must start with https://.'

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BACKUP_DIR="$(realpath -m -- "$BACKUP_DIR")"
case "$BACKUP_DIR" in
  "$repo_root"|"$repo_root"/*) fail 'Credential backups must not be stored inside the Git checkout.' ;;
esac
[[ ! -e "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] || fail 'Backup directory already exists. Reuse the original keys instead of regenerating them.'
[[ -d "$(dirname -- "$BACKUP_DIR")" ]] || fail 'Create a secure backup parent directory first.'

context="$(kubectl config current-context)"
[[ -n "$context" ]] || fail 'Select the intended Kubernetes context first.'
kubectl get namespace "$NAMESPACE" >/dev/null
existing_secrets="$(kubectl -n "$NAMESPACE" get secrets -o jsonpath='{.items[*].metadata.name}')"
for secret_name in infisical-secrets infisical-redis-auth; do
  case " $existing_secrets " in
    *" $secret_name "*) fail "$secret_name already exists. This helper never replaces existing credentials." ;;
  esac
done

printf 'Context: %s; namespace: %s\n' "$context" "$NAMESPACE"
printf 'Enter the password already assigned to the infisical PostgreSQL role.\n'
read -r -s -p 'Database password: ' db_password
printf '\n'
[[ -n "$db_password" ]] || fail 'The database password must not be empty.'
trap 'unset db_password INFISICAL_SETUP_DB_PASSWORD' EXIT

mkdir -m 0700 -- "$BACKUP_DIR"
openssl rand -hex 16 | tr -d '\r\n' > "$BACKUP_DIR/ENCRYPTION_KEY"
openssl rand -base64 32 | tr -d '\r\n' > "$BACKUP_DIR/AUTH_SECRET"
openssl rand -hex 32 | tr -d '\r\n' > "$BACKUP_DIR/redis-password"
printf '%s' "$SITE_URL" > "$BACKUP_DIR/SITE_URL"

export INFISICAL_SETUP_DB_PASSWORD="$db_password"
python3 - "$DB_HOST" <<'PYTHON' > "$BACKUP_DIR/DB_CONNECTION_URI"
import os
import sys
from urllib.parse import quote

password = quote(os.environ["INFISICAL_SETUP_DB_PASSWORD"], safe="")
sys.stdout.write(f"postgresql://infisical:{password}@{sys.argv[1]}:5432/infisical")
PYTHON
unset db_password INFISICAL_SETUP_DB_PASSWORD
printf 'redis://default:%s@infisical-redis.%s.svc.cluster.local:6379' \
  "$(cat "$BACKUP_DIR/redis-password")" "$NAMESPACE" > "$BACKUP_DIR/REDIS_URL"

if $APPLY; then
  kubectl -n "$NAMESPACE" create secret generic infisical-redis-auth \
    --from-file="redis-password=$BACKUP_DIR/redis-password"
  kubectl -n "$NAMESPACE" create secret generic infisical-secrets \
    --from-file="ENCRYPTION_KEY=$BACKUP_DIR/ENCRYPTION_KEY" \
    --from-file="AUTH_SECRET=$BACKUP_DIR/AUTH_SECRET" \
    --from-file="DB_CONNECTION_URI=$BACKUP_DIR/DB_CONNECTION_URI" \
    --from-file="REDIS_URL=$BACKUP_DIR/REDIS_URL" \
    --from-file="SITE_URL=$BACKUP_DIR/SITE_URL"
fi

printf 'Credential files saved with private permissions in %s\n' "$BACKUP_DIR"
printf 'Back up this directory securely outside the node before storing real secrets in Infisical.\n'
if ! $APPLY; then
  printf 'Secrets were not created; use the recovery commands in application-set/server/infisical/README.md with these same files.\n'
fi
