#!/usr/bin/env bash
set -Eeuo pipefail

VOLUME="monitoring_prometheus-storage"
NAMESPACE="monitoring"
ARGO_NAMESPACE="server"
ARGO_APP="kube-prometheus-stack-dev"
BACKUP_ROOT="/var/backups/k3s-monitoring/prometheus"
PVC=""
EXECUTE=false
ASSUME_YES=false
ALLOW_MAJOR_UPGRADE=false
RESTORE_ARCHIVE=""

usage() {
  sed -n '2,45p' "$0"
  exit "${1:-0}"
}

# Safe by default: discovery and a plan only.
#
# Usage:
#   ./scripts/migrate-prometheus-data.sh
#   ./scripts/migrate-prometheus-data.sh --execute
#   ./scripts/migrate-prometheus-data.sh --execute --allow-major-upgrade
#   ./scripts/migrate-prometheus-data.sh --restore /path/to/k3s-prometheus-before.tar.gz --execute
#
# Options:
#   --volume NAME               Docker volume (default: monitoring_prometheus-storage)
#   --namespace NAME            Kubernetes namespace (default: monitoring)
#   --pvc NAME                  Destination PVC; auto-detected when omitted
#   --argo-application NAME     Application paused during the copy
#   --backup-root PATH          Backup root on the server
#   --execute                   Perform the migration; omission means dry-run
#   --yes                       Skip the final typed confirmation
#   --allow-major-upgrade       Permit Prometheus major-version mismatch
#   --restore ARCHIVE           Restore a destination backup instead of Docker data
#   -h, --help                  Show this help

while (($#)); do
  case "$1" in
    --volume) VOLUME="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --pvc) PVC="$2"; shift 2 ;;
    --argo-application) ARGO_APP="$2"; shift 2 ;;
    --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --allow-major-upgrade) ALLOW_MAJOR_UPGRADE=true; shift ;;
    --restore) RESTORE_ARCHIVE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage 2 ;;
  esac
done

KUBECTL=(k3s kubectl)
DOCKER=(docker)
SUDO=(sudo)

need() { command -v "$1" >/dev/null || { printf 'Missing command: %s\n' "$1" >&2; exit 1; }; }
need sudo
need tar
need find

docker_mount=""
docker_container=""
docker_image=""
prometheus_cr=""
pv=""
destination=""
new_image=""
old_version=""
new_version=""
destination_owner=""

if [[ -z "$RESTORE_ARCHIVE" ]]; then
  docker_mount="$(${DOCKER[@]} volume inspect --format '{{ .Mountpoint }}' "$VOLUME")"
  docker_container="$(${DOCKER[@]} ps -a --filter "volume=$VOLUME" --format '{{.Names}}' | sed -n '1p')"
  [[ -n "$docker_container" ]] || { printf 'No container uses Docker volume %s\n' "$VOLUME" >&2; exit 1; }
  docker_image="$(${DOCKER[@]} inspect --format '{{.Config.Image}}' "$docker_container")"
  old_version="$(${DOCKER[@]} exec "$docker_container" prometheus --version 2>&1 | sed -nE 's/^prometheus, version ([^ ]+).*/\1/p')"
fi

if [[ -z "$PVC" ]]; then
  PVC="$(${KUBECTL[@]} -n "$NAMESPACE" get pvc -o custom-columns=NAME:.metadata.name --no-headers | awk '/prometheus/ {print $1; exit}')"
fi
[[ -n "$PVC" ]] || { printf 'Prometheus PVC was not found in namespace %s\n' "$NAMESPACE" >&2; exit 1; }

pv="$(${KUBECTL[@]} -n "$NAMESPACE" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')"
destination="$(${KUBECTL[@]} get pv "$pv" -o jsonpath='{.spec.hostPath.path}')"
[[ -n "$destination" ]] || { printf 'PV %s is not a local-path hostPath volume\n' "$pv" >&2; exit 1; }

prometheus_cr="$(${KUBECTL[@]} -n "$NAMESPACE" get prometheus -o jsonpath='{.items[0].metadata.name}')"
new_image="$(${KUBECTL[@]} -n "$NAMESPACE" get prometheus "$prometheus_cr" -o jsonpath='{.spec.image}')"
new_version="$(sed -nE 's/.*:v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$new_image")"
destination_owner="$(${SUDO[@]} stat -c '%u:%g' "$destination")"

printf 'Operation           : %s\n' "$( [[ -n "$RESTORE_ARCHIVE" ]] && printf restore || printf migrate )"
printf 'Mode                : %s\n' "$( $EXECUTE && printf EXECUTE || printf DRY-RUN )"
printf 'Kubernetes PVC      : %s/%s\n' "$NAMESPACE" "$PVC"
printf 'Kubernetes PV path  : %s\n' "$destination"
printf 'Kubernetes image    : %s\n' "$new_image"
printf 'Destination owner   : %s\n' "$destination_owner"
${SUDO[@]} du -sh "$destination"

if [[ -z "$RESTORE_ARCHIVE" ]]; then
  printf 'Docker volume       : %s\n' "$VOLUME"
  printf 'Docker path         : %s\n' "$docker_mount"
  printf 'Docker container    : %s\n' "$docker_container"
  printf 'Docker image        : %s\n' "$docker_image"
  printf 'Version comparison  : %s -> %s\n' "${old_version:-unknown}" "${new_version:-unknown}"
  ${SUDO[@]} du -sh "$docker_mount"

  old_major="${old_version%%.*}"
  new_major="${new_version%%.*}"
  if [[ "$old_major" =~ ^[0-9]+$ && "$new_major" =~ ^[0-9]+$ && "$old_major" != "$new_major" ]]; then
    printf 'WARNING: Prometheus major versions differ (%s -> %s).\n' "$old_major" "$new_major" >&2
    if $EXECUTE && ! $ALLOW_MAJOR_UPGRADE; then
      printf 'Re-run only after reviewing release notes, with --allow-major-upgrade.\n' >&2
      exit 1
    fi
  fi
else
  [[ -f "$RESTORE_ARCHIVE" ]] || { printf 'Restore archive not found: %s\n' "$RESTORE_ARCHIVE" >&2; exit 1; }
  printf 'Restore archive     : %s\n' "$RESTORE_ARCHIVE"
fi

printf '\nThe execute path will pause Argo reconciliation, stop the new Prometheus,\n'
printf 'stop the old Docker Prometheus, create backups, and replace only the target data.\n'
printf 'It never deletes the Docker volume or a PVC. WAL/chunks_head are not migrated.\n'

$EXECUTE || exit 0

if ! $ASSUME_YES; then
  printf 'Type MIGRATE-PROMETHEUS to continue: '
  read -r answer
  [[ "$answer" == "MIGRATE-PROMETHEUS" ]] || { printf 'Cancelled.\n'; exit 1; }
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$BACKUP_ROOT/$stamp"
target_quarantine="$backup_dir/k3s-target-before"
failed_quarantine="$backup_dir/k3s-target-failed"
success=false
argo_paused=false
docker_stopped=false
target_moved=false

cleanup() {
  rc=$?
  if ! $success; then
    printf 'Migration failed; attempting automatic rollback.\n' >&2
    if $target_moved; then
      ${SUDO[@]} mkdir -p "$failed_quarantine"
      ${SUDO[@]} find "$destination" -mindepth 1 -maxdepth 1 -exec mv -t "$failed_quarantine" -- {} + || true
      ${SUDO[@]} find "$target_quarantine" -mindepth 1 -maxdepth 1 -exec mv -t "$destination" -- {} + || true
      ${SUDO[@]} chown -R "$destination_owner" "$destination" || true
    fi
    ${KUBECTL[@]} -n "$NAMESPACE" patch prometheus "$prometheus_cr" --type merge -p '{"spec":{"replicas":1}}' >/dev/null || true
  fi
  if $docker_stopped; then ${DOCKER[@]} start "$docker_container" >/dev/null || true; fi
  if $argo_paused; then ${KUBECTL[@]} -n "$ARGO_NAMESPACE" annotate application "$ARGO_APP" argocd.argoproj.io/skip-reconcile- >/dev/null || true; fi
  exit "$rc"
}
trap cleanup EXIT

${SUDO[@]} install -d -m 0700 "$backup_dir" "$target_quarantine"
if ${KUBECTL[@]} -n "$ARGO_NAMESPACE" get application "$ARGO_APP" >/dev/null 2>&1; then
  ${KUBECTL[@]} -n "$ARGO_NAMESPACE" annotate application "$ARGO_APP" argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
  argo_paused=true
fi

${KUBECTL[@]} -n "$NAMESPACE" patch prometheus "$prometheus_cr" --type merge -p '{"spec":{"replicas":0}}' >/dev/null
${KUBECTL[@]} -n "$NAMESPACE" wait --for=delete pod -l "prometheus=$prometheus_cr" --timeout=300s >/dev/null 2>&1 || true

if [[ -z "$RESTORE_ARCHIVE" ]]; then
  ${DOCKER[@]} stop --time 60 "$docker_container" >/dev/null
  docker_stopped=true
  ${SUDO[@]} tar -C "$docker_mount" -czf "$backup_dir/docker-prometheus-full.tar.gz" .
fi
${SUDO[@]} tar -C "$destination" -czf "$backup_dir/k3s-prometheus-before.tar.gz" .
${SUDO[@]} find "$destination" -mindepth 1 -maxdepth 1 -exec mv -t "$target_quarantine" -- {} +
target_moved=true

if [[ -n "$RESTORE_ARCHIVE" ]]; then
  ${SUDO[@]} tar -C "$destination" -xzf "$RESTORE_ARCHIVE"
else
  # Immutable TSDB blocks are migrated. Volatile WAL/head/lock data is deliberately excluded.
  ${SUDO[@]} tar -C "$docker_mount" --exclude='./wal' --exclude='./wbl' --exclude='./chunks_head' --exclude='./lock' --exclude='./queries.active' --exclude='./snapshots' -cf - . \
    | ${SUDO[@]} tar -C "$destination" -xf -
fi
${SUDO[@]} chown -R "$destination_owner" "$destination"

${KUBECTL[@]} -n "$NAMESPACE" patch prometheus "$prometheus_cr" --type merge -p '{"spec":{"replicas":1}}' >/dev/null
if ! ${KUBECTL[@]} -n "$NAMESPACE" wait --for=condition=Ready pod -l "prometheus=$prometheus_cr" --timeout=300s; then
  printf 'New Prometheus did not become Ready. Rollback will run.\n' >&2
  exit 1
fi

success=true
printf 'Migration completed. Backups are in %s\n' "$backup_dir"
printf 'The old Docker volume was retained and its container is restarted by cleanup.\n'
