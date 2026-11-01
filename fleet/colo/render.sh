#!/usr/bin/env bash
#
# render.sh — deterministically compose a colo node's FINAL Talos machine config
# from Git (base + role + per-node patches) and SOPS (secrets + inventory).
#
# This is the "thin logic we own" under the Flux+Talos (Option A) lifecycle model:
# node-ADD is "edit files in Git, run this, stage + one-time PXE" — never a hand-run
# `talosctl gen config`. Deterministic: same inputs -> same output.
#
#   ./render.sh <host>                 # render + validate -> out/<host>.machineconfig.yaml
#   ./render.sh <host> --apply <ip>    # also apply to a running node (CHANGES it)
#
# Requires: talosctl, sops, yq. The SOPS age PRIVATE key must be loadable (SOPS_AGE_KEY
# or ~/colo-private/colo-age.key). Decrypted material is written only under a tmpdir
# shredded on exit.
#
# Inventory (secrets/inventory.sops.yaml) must define:
#   COLO_CLUSTER_NAME, COLO_ENDPOINT (https://<cp-ip>:6443),
#   COLO_TALOS_VERSION (e.g. v1.11.5 to adopt the running fleet; bump to roll upgrades),
#   COLO_K8S_VERSION   (e.g. v1.34.1), COLO_SCHEMATIC_ID (bnx2 Image Factory id),
#   COLO_INSTALL_DISK  (e.g. /dev/sda).
set -euo pipefail

HOST="${1:?usage: render.sh <host> [--apply <node-ip>]}"; shift || true
APPLY_IP=""
[[ "${1:-}" == "--apply" ]] && APPLY_IP="${2:?--apply needs <node-ip>}"

DIR="$(cd "$(dirname "$0")" && pwd)"
SEC="$DIR/enc"
OUT="$DIR/out"; mkdir -p "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

case "$HOST" in
  hammer) ROLE="controlplane" ;;
  *)      ROLE="worker" ;;
esac

# --- decrypt inputs into tmpfs ---------------------------------------------------
sops -d "$SEC/inventory.sops.yaml"        > "$TMP/inventory.yaml"
sops -d "$SEC/machine-pki.sops.yaml"      > "$TMP/secrets.yaml"
sops -d "$SEC/nodes/$HOST.sops.yaml"       > "$TMP/node.yaml"
# Talos ingress firewall documents (NetworkDefaultActionConfig + NetworkRuleConfig
# with the real allow-list). SOPS-encrypted because the allow-list is inventory.
sops -d "$SEC/firewall.sops.yaml"         > "$TMP/firewall.yaml"

inv() { yq -r ".$1" "$TMP/inventory.yaml"; }
CLUSTER="$(inv COLO_CLUSTER_NAME)"; ENDPOINT="$(inv COLO_ENDPOINT)"
TALOS_V="$(inv COLO_TALOS_VERSION)"; K8S_V="$(inv COLO_K8S_VERSION)"
SCHEMATIC="$(inv COLO_SCHEMATIC_ID)"; DISK="$(inv COLO_INSTALL_DISK)"

# --- base config from the EXISTING cluster secrets, pinned to the fleet version --
# (adopts the running cluster identity; --talos-version fixes the CONFIG MODEL so
#  patches match the version the live nodes actually run)
talosctl gen config "$CLUSTER" "$ENDPOINT" \
  --with-secrets "$TMP/secrets.yaml" \
  --talos-version "$TALOS_V" --kubernetes-version "$K8S_V" \
  --output-types "$ROLE" --output "$TMP/$ROLE.yaml" --force

# --- version-pinned install patch (image + disk) built from inventory ------------
cat > "$TMP/install.yaml" <<EOF
machine:
  install:
    disk: ${DISK}
    image: factory.talos.dev/installer/${SCHEMATIC}:${TALOS_V}
    wipe: false
EOF

# --- layer patches: base -> role -> install -> per-node --------------------------
talosctl machineconfig patch "$TMP/$ROLE.yaml" \
  --patch "@$DIR/talos/base.yaml" \
  --patch "@$DIR/talos/$ROLE.yaml" \
  --patch "@$TMP/install.yaml" \
  --patch "@$TMP/node.yaml" \
  --output "$OUT/$HOST.machineconfig.yaml"

# --- append the Talos ingress firewall documents --------------------------------
# SECURITY: the cluster restricts Talos API (50000) + kube-API (6443) to an
# allow-list via NetworkDefaultActionConfig + NetworkRuleConfig. These are SEPARATE
# config documents, so they are appended (not merged). Without them a reinstall
# would re-open the APIs to the internet.
{ printf '\n---\n'; cat "$TMP/firewall.yaml"; } >> "$OUT/$HOST.machineconfig.yaml"

# --- guard: refuse to proceed if the firewall documents are missing -------------
if ! grep -q 'kind: NetworkRuleConfig' "$OUT/$HOST.machineconfig.yaml"; then
  echo "ABORT: rendered config lacks the ingress firewall (NetworkRuleConfig). Refusing to apply." >&2
  exit 1
fi

talosctl validate --mode metal --config "$OUT/$HOST.machineconfig.yaml"
echo "rendered + validated (incl. ingress firewall): $OUT/$HOST.machineconfig.yaml  (role=$ROLE, talos=$TALOS_V, k8s=$K8S_V)"

if [[ -n "$APPLY_IP" ]]; then
  echo ">>> applying to $HOST @ $APPLY_IP (this changes the live node)"
  talosctl --talosconfig "$TMP/talosconfig" -e "$APPLY_IP" -n "$APPLY_IP" \
    apply-config -f "$OUT/$HOST.machineconfig.yaml" --mode auto
fi
