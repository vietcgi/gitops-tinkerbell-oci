# fleet/colo — Talos node lifecycle, from Git (Option A)

This tree is the **declarative source of truth for the colo Talos *nodes*** (machine
configs + inventory). It is the counterpart to `kubernetes/clusters/colo/`, which
holds the *in-cluster* GitOps (Cilium, LB pool, apps reconciled by Flux).

Lifecycle model = **Flux + thin Talos logic we own** (not Sidero Omni, not CAPI).
See `../../kubernetes/clusters/colo/README.md` for why.

```
fleet/colo/
  talos/base.yaml           # common machine-config patch (all nodes)   [public]
  talos/controlplane.yaml   # role patch: cni:none, kube-proxy off       [public]
  talos/worker.yaml         # role patch                                 [public]
  nodes/<host>.yaml.example # per-node patch TEMPLATES (placeholders)    [public]
  schematic.yaml            # Image Factory bnx2-bnx2x pin               [public]
  render.sh                 # compose base+role+node+secrets -> config   [public]
  enc/*.sops.yaml           # machine PKI + inventory + firewall + filled nodes [SOPS]
  out/                      # rendered configs (gitignored)
```

## Node ADD — fully from Git

1. Add `nodes/<host>.yaml.example` (role, interface) and the filled, **encrypted**
   `enc/nodes/<host>.sops.yaml` (real MAC/IP) + the node's entry in
   `enc/inventory.sops.yaml`. Commit.
2. `./render.sh <host>` → validated `out/<host>.machineconfig.yaml` (adopts the
   existing cluster secrets; deterministic).
3. Stage it on the colo boot host and one-time PXE the node:
   `scripts/reinstall.sh <host>` (iPXE serves the pinned Talos asset; the per-MAC
   divert in `handoff.ipxe` is auto-removed after the initramfs fetch).
4. The node joins with the shared cluster token; Cilium's DaemonSet schedules onto
   it automatically (Flux already manages Cilium). No hand-run `talosctl`/`cilium`.

> First control plane only, one time: `talosctl bootstrap` to init etcd. Every
> subsequent node is pure join.

## Node REMOVE — the hard part (built last, Git-gated)

Removal is a **storage/quorum operation**, not a delete — it must drain, leave etcd,
wipe, and power off, and survive a controller restart mid-operation. Planned as a
lean, idempotent, Git-gated Job (a `state: Absent` flag on the node's entry triggers
it), with required gates: `drained` → `etcd-left` (quorum-safe) → `wiped` → `powered-off`.
**Until that Job is proven, removal stays a reviewed one-command script** — you remove
nodes rarely, so this is an acceptable day-1 gap. (This is the only part of "fully
GitOps" intentionally deferred.)

## Bootstrap (one-time, per the plan)

1. Load the SOPS age key for render.sh (`enc/README.md`). In-cluster app secrets use sealed-secrets, so Flux does not need SOPS.
2. Cilium already hand-installed on colo → the HelmRelease in `clusters/colo` adopts it.
3. `flux bootstrap github --owner=vietcgi --repository=gitops-tinkerbell-oci \
   --branch=main --path=kubernetes/clusters/colo` — run from a firewall-allow-listed
   host (`.67` or an Oracle IP). Flux then reconciles the colo addons + apps.

## Secrets & inventory

Real MACs/IPs/`/27`/BMC + the Talos PKI are **SOPS-encrypted** here, never committed
in plaintext (enforced by `enc/.gitignore`). In-cluster app secrets keep using
sealed-secrets. See `enc/README.md`.
