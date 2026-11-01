# Omni platform — stand it up from zero

Everything needed to rebuild the Omni + Dex control plane on a fresh OCI node, reproducibly.
The manifests in `../` are declarative and Flux-managed; the only non-declarative pieces are
three secrets (a GPG etcd key, the shared OIDC client secret, the Dex admin password). This
directory makes **those** reproducible too, so the whole platform is in code.

## What's a secret vs. what's in Git

| Thing | Where it lives | Reproducible by |
|---|---|---|
| StatefulSet, Dex, Service, PVC, Certificate, Namespace | `../*.yaml` (committed) | Flux |
| TLS cert (`omni-tls`) | issued by cert-manager (Let's Encrypt DNS-01) | cert-manager, automatically |
| `omni-etcd-key` / `omni-config` / `omni-dex-config` | `../sealed-secret.yaml` (committed, encrypted) | **`./seal-secrets.sh`** |
| admin IP allow-list | `terraform/secrets.auto.tfvars` (gitignored) | you re-enter it |
| omniconfig + CI service-account key | never committed | the import runbook |

## Full from-scratch sequence

```
# 1. Infra: VCN, node, firewall (admin ports locked to your allow-list)
cd terraform && terraform apply            # needs secrets.auto.tfvars (admin_source_cidrs)

# 2. Core platform via Flux (sealed-secrets controller, cert-manager, cilium already in the repo)
#    Flux reconciles kubernetes/ onto the node. Label the node so Omni/Dex schedule on it:
kubectl label node <node> omni.sidero.dev/host=true

# 3. Regenerate + seal the three Omni secrets for THIS cluster, then commit
cd kubernetes/apps/omni/bootstrap
./seal-secrets.sh --force                  # prints a fresh admin password — save it
git add ../sealed-secret.yaml && git commit -m "omni: reseal deploy secrets"

# 4. Flux applies the sealed secrets; the sealed-secrets controller decrypts them in-cluster.
#    omni-0 + dex come up. Browser-login at https://omni.<domain>:8443 with the printed password.

# 5. Adopt the colo cluster — see the private repo: gitops-colo-la/infra/omni/IMPORT-RUNBOOK.md
```

## Why `seal-secrets.sh` must run per-cluster

Sealed secrets are encrypted to the **sealed-secrets controller's public cert**, which is unique
per cluster install. The committed `../sealed-secret.yaml` only decrypts on the cluster it was
sealed against. Rebuild the cluster (or reinstall sealed-secrets) → the controller gets a new
cert → re-run `./seal-secrets.sh --force` and commit the new file. See `./seal-secrets.sh` header
for the safety rails (it won't clobber an existing file without `--force`; regenerating the etcd
key makes any existing Omni data undecryptable, so it's a fresh-deploy tool).

## The fixed identifiers (safe to keep across rebuilds)

- `--account-id` in `../statefulset.yaml` (`3F842767-…`) — Omni's own account UUID. Keep it stable
  so machine/cluster resource IDs stay consistent; it's not a secret.
- hostnames `omni.qualityspace.com` / `auth.qualityspace.com` and the node private IP in
  `hostAliases` (`10.0.1.67`) — update the hostAliases if the node's private IP changes.

Everything else regenerates from `seal-secrets.sh`.
