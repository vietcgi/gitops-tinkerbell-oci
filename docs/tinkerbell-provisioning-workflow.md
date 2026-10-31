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
never prepared and never turns PXE on. `disabled` does **not** stop a Workflow
that is already PREPARING/PENDING/RUNNING: see below.

## Aborting an install in progress

What Tinkerbell v0.25 actually does, which dictates the order:

- tink-agent finishes the action it is running no matter what happens to the
  Workflow object; only the action's own timeout or stopping the machine ends it.
- tink-server keeps serving the next action of a prepared Workflow; setting
  `disabled: true` on it changes nothing.
- Deleting the Workflow stops further actions, but does **not** set `allowPXE`
  back to false (that only happens on SUCCESS).
- If Git still says `disabled: false`, Flux recreates the deleted Workflow and the
  install starts again from the beginning.
- If the machine reboots while the Workflow exists, it PXE-boots and carries on.

So, in this order:

1. **Power the server off** (console or iDRAC). Off, not reboot.
2. In Git set `disabled: true` on that Workflow, push, and make Flux apply it:
   ```bash
   K="sudo k3s kubectl"
   $K -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   $K -n flux-system annotate kustomization infrastructure reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   $K -n tink-system get workflow <name> -o jsonpath='{.spec.disabled}{"\n"}'   # wait for: true
   ```
3. Delete the live Workflow. Flux recreates it disabled (never prepared, no tasks):
   `$K -n tink-system delete workflow <name>`
4. Turn PXE off on the Hardware (every host here has one interface):
   ```bash
   $K -n tink-system patch hardware <hw> --type=json \
     -p '[{"op":"replace","path":"/spec/interfaces/0/netboot/allowPXE","value":false}]'
   curl -s -o /dev/null -w '%{http_code}\n' http://tinkerbell.qualityspace.com/ipxe/script/<mac>/auto.ipxe   # want 404
   ```
5. Power on. The disk may be half-written; if it does not boot, reinstall with a
   new Workflow name.

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
  or turn `allowPXE` off on the live Hardware (step 4 above) to boot the disk.
- **Disk steps fail instead of masking errors.** Image downloads are checked
  against a pinned SHA256. Once an image starts being written, any failure
  (download, checksum, decompress, write) zeroes the first 64 MiB and the last
  1 MiB of the disk (MBR, primary and backup GPT) so a partial image is not left
  looking bootable. A failed partition-table refresh, a stale kernel partition
  mapping, and mount, initramfs, GRUB or unmount errors all fail the action. This
  makes SUCCESS (which turns PXE off) mean every step completed; it is not a boot
  test. Each template was install- and boot-tested in QEMU on 2026-10-30.
- **Inside HookOS:** `docker logs tink-worker --follow` on the console.

## Access

Installed hosts are SSH key only (`ssh_pwauth: false`, `lock_passwd: true`).
No password hashes live in this repo: it is public, so any hash is crackable
offline. Console passwords, where set, are managed out of band.
