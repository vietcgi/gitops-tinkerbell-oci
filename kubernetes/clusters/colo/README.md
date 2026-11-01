# colo cluster (Talos) — GitOps root

This is the **additive** Flux root for the colo bare-metal **Talos** cluster
(hammer `.69` control-plane + talos-13 `.70` + talos-14 `.71`, growing to the
R610 fleet). It lives in the **same repo** as the OCI k3s cluster, per the
settled platform plan, but is a **separate cluster** with its own Flux.

## Why this does not disturb OCI

The existing OCI cluster's Flux only reconciles these paths (see
`kubernetes/flux-kustomizations.yaml`):

- `./kubernetes/infrastructure`
- `./kubernetes/infrastructure-config`
- `./kubernetes/apps`

It does **not** recurse into `kubernetes/clusters/`. Everything here is reconciled
only by the **colo** cluster's own Flux, so adding these files changes nothing on OCI.

## Layout

```
clusters/colo/
  versions.yaml                # fleet version lock ("latest everything" + upgrade caveats)
  infrastructure.yaml          # Flux Kustomizations (what colo reconciles, in order)
  infrastructure/              # Layer 1: CNI + core (Cilium adopted for Talos)
    cilium/                    #   Talos-shaped: KubePrism :7445, LB-IPAM, L2
  infrastructure-config/       # Layer 2: post-CRD config (LB pool, L2 policy)
```

## Talos vs the OCI (k3s) Cilium — the key differences

| | OCI (k3s) `kubernetes/infrastructure/cilium` | colo (Talos) `clusters/colo/infrastructure/cilium` |
|---|---|---|
| API endpoint | `localhost:6443` (k3s) | `localhost:7445` (**Talos KubePrism**) |
| Chart | 1.18.4 | 1.21.0 (latest stable — see `versions.yaml`) |
| LB pool | `10.0.1.200/32` | the colo public **/27** (templated; real block out of repo) |
| CNI | Cilium (k3s `--flannel-backend=none`) | Talos `cni: none` set in machine config |

## Day-1 bootstrap (not yet run)

Cilium must exist **before** Flux (no-CNI bootstrap). On colo it is already
hand-installed via Helm (release `cilium`/`kube-system`), so the HelmRelease here
**adopts** it — verify values converge on first reconcile, do not reinstall.

To bring colo under Flux (run against the colo kubeconfig, from a host allow-listed
by the Talos ingress firewall — e.g. `.67` or an Oracle IP):

```sh
flux bootstrap github \
  --owner=vietcgi --repository=gitops-tinkerbell-oci \
  --branch=main --path=kubernetes/clusters/colo \
  --personal
```

## Decision still open (node lifecycle owner)

Cluster **addons + apps + node add + bootstrap** are GitOps via this tree.
Automated node **removal** (drain → leave etcd → wipe → power-off, quorum/PDB-safe)
is the one hard piece — being built as a lean, Git-gated reconciler/Job we own
(chosen over Sidero Omni to avoid licensing/lock-in and to not deepen reliance on
client-owned `.67`). Until that Job is proven, removal stays a one-command script.

## Secrets / inventory

Real IPs, MACs, and the `/27` block **never** go in this public repo. They live in
`~/colo-private/` and are injected via sealed-secret (repo already uses
sealed-secrets) or SOPS. Placeholders here are marked `# TODO(colo-private)`.
