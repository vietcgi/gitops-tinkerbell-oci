# Tinkerbell Provisioning Workflow

Everything is driven from Git. There are no provisioning scripts; the old
`provision.sh` / `provision-server.sh` / `init-netboot.sh` (kubectl patching of
`allowPXE`, suspending Flux, deleting Workflows) were removed because they
conflicted with this lifecycle.

## How a boot is decided

```
BIOS PXE -> .67 dhcpd (fixed IP by MAC) -> TFTP undionly-embedded.kpxe
  -> http://108.181.38.67:8080/handoff.ipxe
  -> http://tinkerbell.qualityspace.com/ipxe/script/<mac>/auto.ipxe   (Smee)
       allowPXE=true  -> 200, HookOS -> tink-agent runs the Workflow
       allowPXE=false -> 404 -> handoff `exit` -> BIOS next device -> disk
```

`allowPXE` is owned by the Tinkerbell controller, not Flux:

- Workflows set `bootOptions.toggleAllowNetboot: true`: PXE on while preparing,
  off after the Workflow reaches SUCCESS.
- Hardware carries `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`, so Flux creates
  it once and never overwrites the toggle (`spec.interfaces` is an atomic list).
  Cost: later Git edits to an existing Hardware only apply after deleting the
  live object. kustomize-controller is v1.7.3; `.spec.ignore` needs >= v1.9.
- The last template action is `waitdaemon` (reboot 30s after reporting SUCCESS),
  so the Workflow can actually reach SUCCESS before HookOS dies.

## Install / reinstall a server

1. In `kubernetes/infrastructure/tinkerbell/workflows.yaml`, give the host's single
   Workflow a **new name** (e.g. `hammer-ubuntu-2604-r4`) and set `disabled: false`.
   Rename instead of adding a second Workflow: tink-server stops at the first
   non-pending Workflow for an agent, so a leftover one blocks the new install.
2. Push. Smee starts returning 200 for the MAC.
3. Reboot the server (SSH, or power-cycle from the console).
4. Wait for SUCCESS: Smee flips to 404, the box reboots from disk.
5. Commit `disabled: true` on that Workflow.

Step 5 matters: Workflow status lives only in the cluster. If the object is ever
recreated (cluster rebuild, someone deletes it), an enabled spec runs the install
again and **wipes the disk** on the next PXE boot. A recreated disabled Workflow is
never prepared and never turns PXE on. Note `disabled` does not stop a Workflow
that is already PREPARING/PENDING/RUNNING; delete the live object for that.

## Checking state (from the OCI node)

```bash
ssh ubuntu@170.9.8.103
K="sudo k3s kubectl -n tink-system"
$K get workflows.tinkerbell.org -o custom-columns=NAME:.metadata.name,STATE:.status.state,DISABLED:.spec.disabled
$K get hardware.tinkerbell.org -o custom-columns=NAME:.metadata.name,PXE:.spec.interfaces[0].netboot.allowPXE
curl -s -o /dev/null -w '%{http_code}\n' http://tinkerbell.qualityspace.com/ipxe/script/<mac>/auto.ipxe
```

## Failure modes

- **FAILED / TIMEOUT leaves PXE on.** The server keeps booting HookOS (the failed
  Workflow does not re-run). Fix the cause, then either rename to a new Workflow,
  or set `allowPXE` false on the live Hardware to boot the disk.
- **Inside HookOS:** `docker logs tink-worker --follow` on the console.

## Access

Installed hosts are SSH key only (`ssh_pwauth: false`, `lock_passwd: true`).
No password hashes live in this repo: it is public, so any hash is crackable
offline. Console passwords, where set, are managed out of band.
