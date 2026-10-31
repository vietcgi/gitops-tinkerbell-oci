#!/bin/bash
#
# Reinstall a colo server through Tinkerbell, end to end.
#
#   scripts/reinstall.sh <host> [--dry-run]
#   scripts/reinstall.sh anvil --allow-production --confirm anvil
#
# 1. Preflight: clean checkout in sync with origin/main, exactly one Workflow
#    for <host> in Git, no install already active, iDRAC reachable.
# 2. Rename the host's Workflow (-rN -> -rN+1), set disabled: false, push,
#    and wait until Flux has applied that exact commit and the new Workflow is
#    PENDING with PXE allowed and the host's iPXE script served.
# 3. Via the colo boot host: one-time PXE + power cycle (bmc-power on .67).
# 4. Watch the Workflow. On SUCCESS, confirm PXE is off, then commit
#    disabled: true (see the lifecycle notes at the top of workflows.yaml).
#
# Wipes the host's disk. Needs SSH to the cluster node and the colo host.
#
set -euo pipefail

WF_FILE=kubernetes/infrastructure/tinkerbell/workflows.yaml
CLUSTER=ubuntu@170.9.8.103
COLO=kevin@108.181.38.67
NS=tink-system
IPXE_URL=http://tinkerbell.qualityspace.com/ipxe/script
PRODUCTION_HOSTS=" anvil "
WATCH_TIMEOUT=3600

# One multiplexed connection per host: .67 rate-limits new SSH connections.
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=auto
     -o "ControlPath=~/.ssh/cm-%C" -o ControlPersist=15m)

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '%s  ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
k()    { "${SSH[@]}" "$CLUSTER" "sudo k3s kubectl -n $NS $(printf '%q ' "$@")"; }
kf()   { "${SSH[@]}" "$CLUSTER" "sudo k3s kubectl -n flux-system $(printf '%q ' "$@")"; }

usage() { sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

host="" dry_run=0 allow_prod=0 confirm=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry_run=1 ;;
    --allow-production) allow_prod=1 ;;
    --confirm) confirm=${2:-}; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$host" ] || die "only one host"; host=$1 ;;
  esac
  shift
done
[ -n "$host" ] || usage
[[ $host =~ ^[a-z0-9-]+$ ]] || die "invalid host name: $host"

if [[ $PRODUCTION_HOSTS == *" $host "* ]]; then
  [ $allow_prod = 1 ] && [ "$confirm" = "$host" ] \
    || die "$host is production: pass --allow-production --confirm $host"
fi

cd "$(git rev-parse --show-toplevel)"

# --- preflight: Git ---------------------------------------------------------
[ "$(git branch --show-current)" = main ] || die "not on main"
if ! git diff --quiet || ! git diff --cached --quiet; then die "uncommitted changes; commit or stash first"; fi
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "local main differs from origin/main"

sel="select(.kind == \"Workflow\" and .spec.hardwareRef == \"$host\")"
n=$(yq ea "[$sel] | length" "$WF_FILE")
[ "$n" = 1 ] || die "expected exactly one Workflow for $host in $WF_FILE, found ${n:-0}"
old=$(yq "$sel | .metadata.name" "$WF_FILE")
mac=$(yq "$sel | .spec.hardwareMap.device_1" "$WF_FILE")
ip=$(yq "$sel | .spec.hardwareMap.ip_address // \"\"" "$WF_FILE" | cut -d/ -f1)
if [[ $old =~ ^(.*-r)([0-9]+)$ ]]; then
  new="${BASH_REMATCH[1]}$((BASH_REMATCH[2] + 1))"
else
  new="$old-r2"
fi

# --- preflight: cluster -----------------------------------------------------
hw_mac=$(k get hardware "$host" -o 'jsonpath={.spec.interfaces[0].dhcp.mac}') \
  || die "cannot read Hardware $host from the cluster"
[ "$hw_mac" = "$mac" ] || die "MAC mismatch: Workflow says $mac, Hardware $host says $hw_mac"
active=$(k get workflows.tinkerbell.org -o json | jq -r --arg h "$host" \
  '.items[] | select(.spec.hardwareRef == $h and (.status.state == "PENDING" or .status.state == "RUNNING")) | .metadata.name')
[ -z "$active" ] || die "an install is already active for $host: $active"

# --- preflight: BMC -----------------------------------------------------------
power=$("${SSH[@]}" "$COLO" "sudo bmc-power $(printf '%q' "$host") status") \
  || die "iDRAC for $host is not reachable via $COLO (bmc-power status failed)"

log "host=$host mac=$mac ip=${ip:-?}  workflow $old -> $new  ($power)"

yq -i "($sel | .metadata.name) = \"$new\" | ($sel | .spec.disabled) = false" "$WF_FILE"
git --no-pager diff --stat -- "$WF_FILE"
git --no-pager diff -U0 -- "$WF_FILE" | grep -E '^[-+] ' || true
if [ $dry_run = 1 ]; then
  git checkout -q -- "$WF_FILE"
  log "dry run: preflight passed, no changes made"
  exit 0
fi

reconcile() {  # wait until Flux has applied commit $1
  local sha=$1 i
  kf annotate gitrepository flux-system "reconcile.fluxcd.io/requestedAt=$(date +%s)" --overwrite >/dev/null
  for _ in $(seq 1 60); do
    [[ $(kf get gitrepository flux-system -o 'jsonpath={.status.artifact.revision}') == *"$sha"* ]] && break
    sleep 5
  done
  kf annotate kustomization infrastructure "reconcile.fluxcd.io/requestedAt=$(date +%s)" --overwrite >/dev/null
  for _ in $(seq 1 60); do
    [[ $(kf get kustomization infrastructure -o 'jsonpath={.status.lastAppliedRevision}') == *"$sha"* ]] && return 0
    sleep 5
  done
  return 1
}

# --- arm ----------------------------------------------------------------------
git commit -q --no-verify -m "feat($host): reinstall ($new)" -- "$WF_FILE"
git push -q --no-verify origin main
sha=$(git rev-parse HEAD)
log "pushed ${sha:0:7}; waiting for Flux"
reconcile "$sha" || die "Flux did not apply ${sha:0:7} within 5 minutes (nothing powered)"

state=""
for _ in $(seq 1 36); do
  state=$(k get workflows.tinkerbell.org "$new" -o 'jsonpath={.status.state}' 2>/dev/null || true)
  [ "$state" = PENDING ] && break
  sleep 5
done
[ "$state" = PENDING ] || die "Workflow $new is '${state:-missing}', not PENDING (nothing powered)"
k get workflows.tinkerbell.org "$old" >/dev/null 2>&1 && die "old Workflow $old still exists (nothing powered)"
pxe=$(k get hardware "$host" -o 'jsonpath={.spec.interfaces[0].netboot.allowPXE}')
[ "$pxe" = true ] || die "allowPXE is '$pxe' on $host (nothing powered)"
curl -fsS --max-time 15 "$IPXE_URL/$mac/auto.ipxe" | grep -q '^kernel ' \
  || die "iPXE script for $mac is not being served (nothing powered)"
log "armed: $new PENDING, allowPXE=true, iPXE script served"

# --- power ----------------------------------------------------------------------
if ! "${SSH[@]}" "$COLO" "sudo bmc-power $(printf '%q' "$host") pxe-boot"; then
  cat >&2 <<EOF
$(date +%H:%M:%S)  ERROR: the power command failed. $host is ARMED: its next PXE boot
           will reinstall it. Not retried automatically. Either reboot it yourself
           to continue, or disarm (docs/tinkerbell-provisioning-workflow.md,
           "Aborting an install in progress").
EOF
  exit 1
fi
log "one-time PXE set and power cycled; watching $new"

# --- watch ----------------------------------------------------------------------
last="" start=$(date +%s)
while :; do
  cur=$(k get workflows.tinkerbell.org "$new" \
    -o 'jsonpath={.status.state} {.status.currentState.actionName} {.status.currentState.state}' 2>/dev/null || true)
  [ -n "$cur" ] && [ "$cur" != "$last" ] && { log "$cur"; last=$cur; }
  case $cur in SUCCESS*|FAILED*|TIMEOUT*) break ;; esac
  [ $(( $(date +%s) - start )) -lt $WATCH_TIMEOUT ] || die "no result after $((WATCH_TIMEOUT / 60)) min; $new is still ${cur:-unknown}"
  sleep 10
done
k get workflows.tinkerbell.org "$new" -o json \
  | jq -r '.status.tasks[].actions[] | "  \(.name)  \(.state)  \(.executionDuration // "-")"'
case $cur in
  SUCCESS*) ;;
  *) die "install did not succeed ($cur). $host may still PXE into HookOS; see \"Aborting an install in progress\"" ;;
esac

# --- disarm ---------------------------------------------------------------------
pxe=$(k get hardware "$host" -o 'jsonpath={.spec.interfaces[0].netboot.allowPXE}')
[ "$pxe" = false ] || die "SUCCESS but allowPXE is still '$pxe'; not committing disabled: true"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$IPXE_URL/$mac/auto.ipxe")
[ "$code" = 404 ] || die "SUCCESS but the iPXE script returns $code, expected 404"

yq -i "($sel | .spec.disabled) = true" "$WF_FILE"
git commit -q --no-verify -m "chore($host): disable $new after successful install" -- "$WF_FILE"
git push -q --no-verify origin main
sha=$(git rev-parse HEAD)
reconcile "$sha" || die "pushed ${sha:0:7} (disabled: true) but Flux has not applied it yet"
[ "$(k get workflows.tinkerbell.org "$new" -o 'jsonpath={.spec.disabled}')" = true ] \
  || die "Workflow $new is not disabled in the cluster"
log "$new SUCCESS; PXE off; disabled: true committed (${sha:0:7})"

# --- wait for the installed OS ------------------------------------------------------
if [ -n "$ip" ]; then
  for _ in $(seq 1 90); do
    if nc -z -G 3 "$ip" 22 2>/dev/null || nc -z -w 3 "$ip" 22 2>/dev/null; then
      log "$host is up: ssh open on $ip"
      exit 0
    fi
    sleep 10
  done
  log "WARNING: ssh on $ip not open after 15 min (R610 POST alone takes ~4.5 min)"
fi
