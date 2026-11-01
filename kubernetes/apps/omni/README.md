# apps/omni — Sidero Omni control plane on the OCI cluster (free-tier)

Omni manages the **colo** Talos cluster (hammer/talos-13/talos-14); it runs **here** on
OCI (a cluster it does NOT manage → no circular dependency, per Sidero). Verified sound by
Codex 2026-11-01.

## Why this shape (no Oracle charges)
- **hostNetwork** → Omni/Dex use the node's **public IP** for the TCP ports + WireGuard
  UDP 50180. No cloud LoadBalancer, no NLB, no Oracle bill.
- **local-path** PVC (free), node-pinned. Back up etcd regularly (no node-loss safety).
- cert-manager (self-signed Issuer here) + sealed-secrets — both already in-cluster, free.

## Go-live steps (fill placeholders, then wire in)
1. Pick the OCI node with a stable **public IP**; label it:
   `kubectl label node <node> omni.sidero.dev/host=true`
2. Open that node's **VCN security list**: TCP 443/8090/8091/8100/5556 + **UDP 50180**.
3. Choose DNS names (`omni.<domain>`, `auth.<domain>`) → point both at the node public IP.
4. Replace every `__PLACEHOLDER__` in these files (OMNI_VERSION, OMNI_DNS, AUTH_DNS,
   NODE_PUBLIC_IP, OMNI_ACCOUNT_UUID=`uuidgen`, OMNI_USER_EMAIL).
5. Create + seal the three secrets (commands in `sealed-secrets.yaml`): `omni-etcd-key`
   (GPG `omni.asc`), `omni-dex-config` (Dex config w/ admin bcrypt hash), and
   `omni-oidc-client` (a random `openssl rand -hex 32` — the SAME value must go in the
   Dex staticClients secret; never the example `omni-dex-secret`).
6. Add `- omni/` to `kubernetes/apps/kustomization.yaml` (NOT before step 5 — a broken
   secret would fail the app), merge → Flux deploys it.
7. Import your CA (`kubectl -n omni-system get secret omni-tls -o jsonpath='{.data.ca\.crt}' | base64 -d`)
   into clients; open `https://omni.<domain>`.

## Then adopt the colo cluster (no wipe)
```
omnictl cluster import --dry-run -n 108.181.38.69 -n 108.181.38.70 -n 108.181.38.71 \
  --talosconfig <os:admin>     # review CNI/kube-proxy/KubePrism/addressing/disk patches
```
Review → import → **unlock in a maintenance window** (rotates cluster CAs) → verify Flux →
`omnictl cluster template export` into gitops for ongoing GitOps.

## Open risks
- Omni is BUSL (production needs Sidero terms — you're handling licensing).
- Single Omni replica + local-path = recoverable, not HA. Add etcd snapshot backups.
