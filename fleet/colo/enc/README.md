# fleet/colo/enc/ — SOPS-encrypted Talos provisioning secrets + inventory

Everything sensitive for colo provisioning lives here **encrypted with SOPS-age**.
Plaintext is blocked by `.gitignore`; only `*.sops.yaml` may be committed.

> Dir is named `enc` (not `secrets`) so these commit-intended, *encrypted* files
> aren't swept up by the repo root `.gitignore` safety-net (`*secret*`, `*.key`).
> For the same reason the PKI bundle is `machine-pki.sops.yaml`, not `*-secrets`.

## What belongs here

| File (encrypted) | Contents |
|---|---|
| `machine-pki.sops.yaml` | The cluster's EXISTING Talos secrets bundle (PKI, tokens, talosconfig identity). **Import the running cluster's secrets — do NOT `talosctl gen secrets` fresh, or every running node is orphaned.** |
| `inventory.sops.yaml` | `COLO_CLUSTER_NAME`, `COLO_ENDPOINT`, `COLO_TALOS_VERSION` (set to running to adopt; bump to roll an upgrade), `COLO_K8S_VERSION`, `COLO_SCHEMATIC_ID`, `COLO_INSTALL_DISK`, the real `/27`/`COLO_GATEWAY`/`COLO_SUBNET`, and per-node MAC/IP/BMC. |
| `firewall.sops.yaml` | Talos ingress-firewall docs (`NetworkDefaultActionConfig` + `NetworkRuleConfig`) with the real allow-list. render.sh appends these and REFUSES to apply a config without them (keeps 6443/50000 locked down). |
| `nodes/<host>.sops.yaml` | The filled-in per-node patch (from `../nodes/<host>.yaml.example`). |

## Why SOPS here (not sealed-secrets)

Talos machine configs are consumed by the installer **before Kubernetes exists**, so
a SealedSecret controller can't decrypt them at provision time. SOPS-age encrypts at
rest in Git and is decrypted by the operator (render.sh). In-cluster *app* secrets
keep using sealed-secrets.

## One-time key setup

```sh
age-keygen -o ~/colo-private/colo-age.key          # keep PRIVATE key off the repo
# copy the printed "age1..." PUBLIC key into /.sops.yaml (creation_rules)
export SOPS_AGE_KEY_FILE=~/colo-private/colo-age.key
```
