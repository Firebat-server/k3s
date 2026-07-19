#!/usr/bin/env bash
set -Eeuo pipefail

VOLUME="monitoring_grafana-storage"
NAMESPACE="monitoring"
ARGO_NAMESPACE="server"
ARGO_APP="kube-prometheus-stack-dev"
BACKUP_ROOT="/var/backups/k3s-monitoring/grafana"
PVC=""
EXECUTE=false
ASSUME_YES=false
ALLOW_MAJOR_UPGRADE=false
RESTORE_ARCHIVE=""

usage() {
  sed -n '2,39p' "$0"
  exit "${1:-0}"
}

# Safe by default. Run without --execute to inspect the migration plan.
#
# Usage:
#   ./scripts/migrate-grafana-data.sh
#   ./scripts/migrate-grafana-data.sh --execute --allow-major-upgrade
#   ./scripts/migrate-grafana-data.sh --restore /path/to/k3s-grafana-before.tar.gz --execute
#
# Options:
#   --volume NAME               Docker volume (default: monitoring_grafana-storage)
#   --namespace NAME            Kubernetes namespace (default: monitoring)
#   --pvc NAME                  Destination PVC; auto-detected when omitted
#   --argo-application NAME     Application paused during the copy
#   --backup-root PATH          Backup root on the server
#   --execute                   Perform the operation
#   --yes                       Skip the typed confirmation
#   --allow-major-upgrade       Permit Grafana major-version mismatch
#   --restore ARCHIVE           Restore a destination backup
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

docker_mount=""
docker_container=""
docker_image=""
deployment=""
new_image=""
old_version=""
new_version=""
pv=""
destination=""

if [[ -z "$RESTORE_ARCHIVE" ]]; then
  docker_mount="$(${DOCKER[@]} volume inspect --format '{{ .Mountpoint }}' "$VOLUME")"
  docker_container="$(${DOCKER[@]} ps -a --filter "volume=$VOLUME" --format '{{.Names}}' | sed -n '1p')"
  [[ -n "$docker_container" ]] || { printf 'No container uses Docker volume %s\n' "$VOLUME" >&2; exit 1; }
  docker_image="$(${DOCKER[@]} inspect --format '{{.Config.Image}}' "$docker_container")"
  old_version="$(${DOCKER[@]} exec "$docker_container" grafana server -v 2>&1 | sed -nE 's/^Version ([^ ]+).*/\1/p')"
fi

if [[ -z "$PVC" ]]; then
  PVC="$(${KUBECTL[@]} -n "$NAMESPACE" get pvc -o custom-columns=NAME:.metadata.name --no-headers | awk '/grafana/ {print $1; exit}')"
fi
[[ -n "$PVC" ]] || { printf 'Grafana PVC was not found in namespace %s\n' "$NAMESPACE" >&2; exit 1; }

pv="$(${KUBECTL[@]} -n "$NAMESPACE" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')"
destination="$(${KUBECTL[@]} get pv "$pv" -o jsonpath='{.spec.hostPath.path}')"
[[ -n "$destination" ]] || { printf 'PV %s is not a local-path hostPath volume\n' "$pv" >&2; exit 1; }
deployment="$(${KUBECTL[@]} -n "$NAMESPACE" get deployment -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')"
new_image="$(${KUBECTL[@]} -n "$NAMESPACE" get deployment "$deployment" -o jsonpath='{.spec.template.spec.containers[?(@.name=="grafana")].image}')"
new_version="$(sed -nE 's/.*:v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$new_image")"
destination_owner="$(${SUDO[@]} stat -c '%u:%g' "$destination")"

printf 'Operation           : %s\n' "$( [[ -n "$RESTORE_ARCHIVE" ]] && printf restore || printf migrate )"
printf 'Mode                : %s\n' "$( $EXECUTE && printf EXECUTE || printf DRY-RUN )"
printf 'Kubernetes PVC      : %s/%s\n' "$NAMESPACE" "$PVC"
printf 'Kubernetes PV path  : %s\n' "$destination"
printf 'Kubernetes image    : %s\n' "$new_image"
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
    printf 'WARNING: Grafana major versions differ (%s -> %s).\n' "$old_major" "$new_major" >&2
    if $EXECUTE && ! $ALLOW_MAJOR_UPGRADE; then
      printf 'Review Grafana upgrade notes and re-run with --allow-major-upgrade.\n' >&2
      exit 1
    fi
  fi
else
  [[ -f "$RESTORE_ARCHIVE" ]] || { printf 'Restore archive not found: %s\n' "$RESTORE_ARCHIVE" >&2; exit 1; }
  printf 'Restore archive     : %s\n' "$RESTORE_ARCHIVE"
fi

printf '\nWARNING: this copies the SQLite database, dashboards, users, plugins and sessions.\n'
printf 'A copied existing database keeps its existing admin password; the new Secret does not overwrite it.\n'
$EXECUTE || exit 0

if ! $ASSUME_YES; then
  printf 'Type MIGRATE-GRAFANA to continue: '
  read -r answer
  [[ "$answer" == "MIGRATE-GRAFANA" ]] || { printf 'Cancelled.\n'; exit 1; }
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
    ${KUBECTL[@]} -n "$NAMESPACE" scale deployment "$deployment" --replicas=1 >/dev/null || true
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

${KUBECTL[@]} -n "$NAMESPACE" scale deployment "$deployment" --replicas=0 >/dev/null
${KUBECTL[@]} -n "$NAMESPACE" rollout status deployment "$deployment" --timeout=300s >/dev/null 2>&1 || true

if [[ -z "$RESTORE_ARCHIVE" ]]; then
  ${DOCKER[@]} stop --time 60 "$docker_container" >/dev/null
  docker_stopped=true
  ${SUDO[@]} tar -C "$docker_mount" -czf "$backup_dir/docker-grafana-full.tar.gz" .
fi
${SUDO[@]} tar -C "$destination" -czf "$backup_dir/k3s-grafana-before.tar.gz" .
${SUDO[@]} find "$destination" -mindepth 1 -maxdepth 1 -exec mv -t "$target_quarantine" -- {} +
target_moved=true

if [[ -n "$RESTORE_ARCHIVE" ]]; then
  ${SUDO[@]} tar -C "$destination" -xzf "$RESTORE_ARCHIVE"
else
  ${SUDO[@]} tar -C "$docker_mount" -cf - . | ${SUDO[@]} tar -C "$destination" -xf -
fi
${SUDO[@]} chown -R "$destination_owner" "$destination"

${KUBECTL[@]} -n "$NAMESPACE" scale deployment "$deployment" --replicas=1 >/dev/null
if ! ${KUBECTL[@]} -n "$NAMESPACE" rollout status deployment "$deployment" --timeout=300s; then
  printf 'New Grafana did not become Ready. Rollback will run.\n' >&2
  exit 1
fi

success=true
printf 'Migration completed. Backups are in %s\n' "$backup_dir"
printf 'The Docker volume was retained and the old container is restarted by cleanup.\n'
