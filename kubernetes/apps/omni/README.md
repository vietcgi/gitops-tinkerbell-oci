# apps/omni — Sidero Omni control plane on the OCI cluster (free-tier)

Omni manages the **colo** Talos cluster (hammer/talos-13/talos-14); it runs **here** on
OCI, a cluster it does NOT manage (no circular dependency). Verified sound by Codex; flags
verified against `ghcr.io/siderolabs/omni:v1.13.1 --help` 2026-11-01.

## The node
Single Always-Free node **`metal-foundry-control-plane`** — `VM.Standard.A1.Flex`,
4 OCPU / 24 GB, **ARM64**, `us-sanjose-1` (west coast — same coast as the LA colo),
current public IP **`170.9.8.103`**. It already runs the production Cilium Gateway + the
client sites + Tinkerbell/Harbor/monitoring. Busy SPOF — **back Omni up** (see bottom).

## Shape (why it's $0 and doesn't disrupt the client sites)
Omni + Dex are **normal pods** that serve their **own Let's Encrypt TLS** on **non-443
hostPorts**, so they:
- **never touch the production Cilium Gateway** (which owns :443 for the client sites) — zero risk to them;
- **need no new/reserved public IP** — they share `170.9.8.103`, so client DNS, Cloudflare origins and the colo firewall allow-list are untouched;
- use **no paid Oracle service** — no load balancer, no block volume. local-path storage only.

| Public endpoint | Port | Purpose |
|---|---|---|
| `omni.qualityspace.com` | **8443/TCP** | Omni UI + API (Omni-served TLS) |
| `omni.qualityspace.com` | **8090/TCP** | SideroLink / machine API (Omni-served TLS) |
| `omni.qualityspace.com` | **8100/TCP** | Kubernetes proxy (Omni-served TLS) |
| `auth.qualityspace.com` | **5556/TCP** | Dex OIDC (Dex-served TLS) |
| `170.9.8.103` | **50180/UDP** | SideroLink WireGuard tunnel |

Event-sink `8091` is internal (travels over the WireGuard tunnel) — **not** exposed.

### Hard don'ts (keep the client sites safe)
Do **not**: add/modify any Gateway listener or HTTPRoute; reserve or reassign the public
IP; upgrade Cilium or the Gateway-API CRDs — none of that is needed for this.

## Go-live steps (fill placeholders, then wire in)
1. Label the node: `kubectl label node metal-foundry-control-plane omni.sidero.dev/host=true`
2. Open the OCI **security list / NSG** for: **8443, 8090, 8100, 5556 TCP + 50180 UDP** (ingress).
3. **DNS (DNS-only / grey-cloud, do NOT proxy):** `omni.qualityspace.com` and
   `auth.qualityspace.com` → **`170.9.8.103`**. (Leave the existing client-site records alone.)
4. Replace `__PLACEHOLDER__`s in `statefulset.yaml`: `OMNI_ACCOUNT_UUID` (`uuidgen`),
   `OMNI_USER_EMAIL`. (Version, ports, URLs are already set. If your domain isn't
   `qualityspace.com`, change the hostnames in statefulset.yaml, certificate.yaml and dex config.)
5. Create + seal the **3 secrets** per the instructions in `sealed-secrets.yaml`:
   `omni-etcd-key` (GPG `omni.asc`), `omni-config` (the OIDC client secret — no CLI flag for
   it), `omni-dex-config` (full Dex config). The OIDC client secret must be the **same** in
   omni-config and omni-dex-config — generate it once with `openssl rand -hex 32`.
6. Add `- omni/` to `kubernetes/apps/kustomization.yaml` (NOT before step 5) → Flux deploys it.
7. Open `https://omni.qualityspace.com:8443` and log in via Dex.

## Then adopt the colo cluster (no wipe)
Omni runs with `--enable-cluster-import`. Adopt the three running Talos nodes in place:
```
omnictl cluster import --dry-run -n 108.181.38.69 -n 108.181.38.70 -n 108.181.38.71 \
  --talosconfig <os:admin>     # review CNI/kube-proxy/KubePrism/addressing/disk patches
```
Review → import → **unlock in a maintenance window** (final adoption rotates cluster CAs;
treat that as a separate, scheduled step) → verify Flux → `omnictl cluster template export`
into gitops for ongoing GitOps.

## Verify before trusting it (Codex's cautions)
- WireGuard UDP via Cilium hostPort: Cilium's kube-proxy replacement does hostPort natively,
  but there's a reported UDP source-port quirk ([cilium#44348](https://github.com/cilium/cilium/issues/44348)).
  Register one node and confirm the tunnel handshake + reconnect after a pod restart before importing the rest.
- k8s-proxy (8100) TLS: confirm it serves TLS with the mounted cert after first boot.

## Backups (single node = recoverable, not HA)
Copy **off the node**, on a schedule: the local-path etcd dir + `omni.db` (sqlite) + the
`omni.asc` etcd key + the Dex config. Snapshots of the *managed* clusters' etcd are NOT a
substitute for Omni's own state.

## Open licensing note
Omni is BUSL (production needs Sidero terms) — you're handling licensing.
