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

One command (wipes the host's disk):

```bash
scripts/reinstall.sh hammer --dry-run   # preflight only, changes nothing
scripts/reinstall.sh hammer
scripts/reinstall.sh anvil --allow-production --confirm anvil   # production
```

It runs the manual steps below and checks each one: clean `main` in sync with
origin, exactly one Workflow for the host, MAC matches the Hardware, no install
already active, iDRAC reachable; then it arms the Workflow, waits for Flux to
apply that exact commit (Workflow PENDING, `allowPXE=true`, iPXE script served),
sets one-time PXE and power-cycles through the iDRAC (see "iDRAC access" below),
watches to SUCCESS, confirms PXE is off and commits `disabled: true`. The power
command is never retried: if it fails, the script stops and says the host is
armed (its next PXE boot reinstalls it).

Manual steps (also what to do for a host without iDRAC access):

1. In `kubernetes/infrastructure/tinkerbell/workflows.yaml`, give the host's single
   Workflow a **new name** (e.g. `hammer-ubuntu-2604-r4`) and set `disabled: false`.
   Rename instead of adding a second Workflow: tink-server stops at the first
   non-pending Workflow for an agent, so a leftover one blocks the new install.
2. Push. Smee starts returning 200 for the MAC.
3. Reboot the server: `ssh kevin@108.181.38.67 sudo bmc-power <host> pxe-boot`,
   or SSH into the host, or power-cycle from the console.
4. Wait for SUCCESS: Smee flips to 404, the box reboots from disk.
5. Commit `disabled: true` on that Workflow.

Do not set `bootOptions.bootMode` on the Workflows: with `netboot`, Tinkerbell's
Rufio would issue its own hard power-off/PXE/power-on through a BMC it cannot
reach. Leaving it unset, the Workflow goes straight to PENDING and the power
step is done by `bmc-power` instead.

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

1. **Power the server off**: `ssh kevin@108.181.38.67 sudo bmc-power <host> off`
   (or the console). Off, not reboot.
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

## iDRAC access

The R610s' iDRAC6 runs in **shared** NIC mode (it uses the eno1 cable). Each
iDRAC has a private address, reachable only from the colo boot host:

| Host | iDRAC | Configured |
|---|---|---|
| hammer | 10.77.0.11/24, no gateway | 2026-10-31 |
| forge, anvil | not yet (factory 192.168.0.x) | |

- `.67` has `10.77.0.1/24` on eno1, added at boot by `bmc-net.service`
  (`scripts/colo/bmc-net.service`, installed in `/etc/systemd/system`, enabled).
  It is deliberately not in netplan; `bmc-power` also re-adds it if a network
  reload drops it.
- `nginx` on `.67` serves `handoff.ipxe` (:8080) and must be enabled at boot
  (`systemctl is-enabled nginx`); it was running but disabled until 2026-10-31.
- `scripts/colo/bmc-power` is installed root-owned at `/usr/local/sbin/bmc-power`
  on `.67`: `sudo bmc-power <host> status|pxe-boot|off`. Hosts are listed in
  `/etc/bmc/hosts` (`name ip user`); each operator password is in
  `/etc/bmc/<host>.pass` (root, 0600). No BMC credential is in Git or the cluster.
- Rufio (Tinkerbell's BMC controller) is not used: the cluster runs in OCI and
  has no route to the iDRACs. One command from `.67` covers the reinstalls here,
  works when the host OS is dead, and keeps the BMC off any tunnel.

iDRAC settings (applied in-band from the host OS with `ipmitool`, root):

- `root`: strong random password (kept out of band); `tinkops` (user 3):
  OPERATOR, the only account `bmc-power` uses.
- IPMI over LAN on (`lan set 1 access on`), lanplus with **cipher suite 3 only**
  (AES, HMAC-SHA1) at OPERATOR level. SOL off. Verified: suites 0-2 and 4-14,
  ADMINISTRATOR logins over LAN, wrong passwords and `root/calvin` are refused.
- **iDRAC6 firmware 1.92 quirk:** the `cipher_privs` string is shifted by one
  position (character *k* sets suite *k+1*). Suite 3 only at OPERATOR is
  `XXoXXXXXXXXXXXX`, not the spec's `XXXoXXXXXXXXXXX` (which disables suite 3).
- The iDRAC web UI (80/443) and SSH (22) also listen on the private address;
  `ipmitool` cannot turn them off.
- Shared mode: the iDRAC drops off the network for ~40 s to ~1.5 min after each
  power change while the LOM renegotiates its link, then answers again, also
  with the server off (tested on hammer 2026-10-31). Wait before re-querying.

To add a host (e.g. forge, at 10.77.0.12):

```bash
# on the host (as root): IPMI over LAN, cipher 3 only, operator user, private IP
ipmitool user set password 2 '<new root password>'
ipmitool user set name 3 tinkops && ipmitool user set password 3 '<operator password>'
ipmitool channel setaccess 1 3 callin=on ipmi=on link=on privilege=3 && ipmitool user enable 3
ipmitool lan set 1 cipher_privs XXoXXXXXXXXXXXX && ipmitool sol set enabled false 1
ipmitool lan set 1 ipsrc static && ipmitool lan set 1 ipaddr 10.77.0.12
ipmitool lan set 1 netmask 255.255.255.0 && ipmitool lan set 1 defgw ipaddr 0.0.0.0
ipmitool lan set 1 access on
# on .67 (as root)
echo "forge 10.77.0.12 tinkops" >> /etc/bmc/hosts
printf '%s' '<operator password>' > /etc/bmc/forge.pass && chmod 600 /etc/bmc/forge.pass
bmc-power forge status
```

Caveat: the iDRAC shares eno1's segment. A private address hides it from the
internet but not from anything else on that L2 segment. If other colo tenants
share it, move the iDRAC to its dedicated port (iDRAC6 Enterprise; hammer reports
a vFlash sensor, which suggests one) or to a VLAN the colo switch enforces.
