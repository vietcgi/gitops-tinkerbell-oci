# 2026-05-21 — baohiemxe.com 11-day outage from stuck k3s upgrade cordon

## TL;DR

`metal3-oci-control` (the single node on the `158.101.99.38` k3s cluster that runs
baohiemxe.com) had been cordoned since **2026-05-10 around 17:00 UTC** by the
`system-upgrade-controller`. The cordon was applied at the start of a k3s
version-upgrade Plan but never released because the upgrade Job failed at the
DNS-resolution step. The orphaned cordon sat unnoticed for 11 days. When
baohiemxe pods were replaced (image bump or pod death) they couldn't reschedule
on the only available node, so the Service had endpoints listed but the pods
behind them were `Pending`. Envoy at the Gateway returned
`upstream connect error or disconnect/reset before headers. reset reason: connection timeout`
to every public request. baohiemxe.com was effectively 503 for 11 days.

Discovered while debugging the qualityspace.com session on 2026-05-21. Fix
applied same day. Both sites green.

## Sequence of events

1. **2026-05-10 ~16:50 UTC** — Flux reconciled the
   `kustomize.toolkit.fluxcd.io/name: infrastructure` kustomization, which
   includes the `system-upgrade-controller` Plan named `k3s-server` (channel
   `https://update.k3s.io/v1-release/channels/v1.34`).
2. The controller cordoned `metal3-oci-control`, drained workloads, and
   started the upgrade Job pod that resolves the latest k3s version from the
   channel URL.
3. **Resolve step failed:**
   ```
   Failed to resolve latest version from Spec.Channel: Get
   "https://update.k3s.io/v1-release/channels/v1.34":
   dial tcp: lookup update.k3s.io on 10.43.0.10:53:
   dial udp 10.43.0.10:53: connect: operation not permitted
   ```
   `connect: operation not permitted` is Cilium denying egress at the eBPF
   layer, not DNS itself failing. Almost certainly a `CiliumNetworkPolicy`
   blocking egress from the `system-upgrade` namespace to either the in-cluster
   DNS service (`kube-dns` at `10.43.0.10:53`) or to external `update.k3s.io`.
4. With the upgrade Job stuck in failure, the controller never reached the
   "uncordon node" step that runs after a successful apply.
5. **Cordon sat from 2026-05-10 through 2026-05-21.** Pods that were already
   running kept running (kubelet doesn't kill pods on a cordoned node).
6. At some point between then and 2026-05-21 ~10:55 UTC, the `baohiemxe`
   Deployment rolled (the two pods we eventually fixed were 105 minutes old at
   the time of repair, so the trigger was earlier; could have been an image
   pull, an OOMKill, an eviction, a Flux reconcile, etc.). The new pods went
   `Pending` because the only node was unschedulable.
7. **2026-05-21 ~12:55 UTC** — public requests to baohiemxe.com started returning
   Envoy `upstream connect error / reset reason: connection timeout`. The
   Service endpoint slice still had the old pod IPs listed for some window;
   eventually both pods were the new Pending ones with no readiness, so the
   Service had no ready endpoints and Envoy could not connect to anything.
8. **2026-05-21 13:41 UTC** — manual `kubectl uncordon metal3-oci-control`
   applied. The two Pending pods immediately scheduled and turned Running.
9. **2026-05-21 13:43 UTC** — the system-upgrade-controller observed the node
   was available, re-ran the Plan. This time the DNS path worked (whether the
   policy was loosened recently or the resolution attempt routed differently is
   not yet confirmed). The upgrade Job completed successfully, applied label
   `plan.upgrade.cattle.io/k3s-server=e233f67ffba71c3bf830a6b60c4f2a5c3954130c8668b22cb9f32423`,
   and properly uncordoned the node.
10. **2026-05-21 13:44 UTC** — verified `curl -sI https://baohiemxe.com/`
    returns `HTTP/2 200`. Site restored.

## Why this hurt

- Single-node cluster. There is no other node to schedule onto when this one is
  cordoned. Any pod replacement is fatal until the cordon is released.
- The upgrade Plan is managed by Flux (`kustomize.toolkit.fluxcd.io/name:
  infrastructure`), so manually deleting the Plan would have just been
  reconciled back. The right repair is fixing whatever blocks the controller's
  DNS path, not deleting the Plan.
- The system-upgrade-controller doesn't time out or roll back a stuck cordon.
  Once it cordons, it expects to be the one that uncordons. If the Job dies
  before the post-apply step, the cordon is permanent until manual action.
- Nothing pages on `node.spec.unschedulable=true` for an extended period.
  Adding a Prometheus alert for `kube_node_spec_unschedulable{} == 1` lasting
  more than ~30 minutes would have caught this within the first hour instead
  of the first 11 days.

## Investigation to-do

1. **Find the policy that blocked egress.** Likely candidate is a
   `CiliumNetworkPolicy` or `CiliumClusterwideNetworkPolicy` restricting either:
   - egress from `system-upgrade` namespace (or the upgrade Job's pod label)
     to `kube-system/kube-dns` on port 53
   - egress from `system-upgrade` to external HTTPS hosts (`update.k3s.io`,
     `github.com`, `releases.k3s.io`)
   Useful commands:
   ```
   kubectl get cnp -A -o yaml | grep -B5 -A30 "system-upgrade\|update.k3s.io"
   kubectl get ccnp -o yaml | grep -B5 -A30 "system-upgrade\|update.k3s.io"
   ```
   Look at Hubble flow logs for the time window of the failed Job:
   ```
   kubectl -n kube-system exec ds/cilium -- cilium hubble observe \
     --since 2026-05-10T16:00:00Z --until 2026-05-10T17:30:00Z \
     --label app.kubernetes.io/name=system-upgrade-controller \
     --verdict DROPPED
   ```
   Or look at the resolve.go path: the Plan's Job runs `rancher/kubectl:v1.30.3`
   in a container named `drain` first, then `system-upgrade-controller` does
   the version-resolve in its own pod (`system-upgrade-controller` namespace,
   `system-upgrade-controller-*` deployment). The version resolve is what
   hit the `operation not permitted` error.
2. **Add an alert for stuck cordons.** Prometheus rule:
   ```
   - alert: NodeCordoned
     expr: kube_node_spec_unschedulable == 1
     for: 30m
     labels: { severity: warning }
     annotations:
       summary: "Node {{ $labels.node }} cordoned for 30+ min"
       description: "Likely a stuck system-upgrade or forgotten maintenance"
   ```
3. **Decide whether single-node `metal3-oci-control` should keep running
   workloads.** If so, the upgrade controller's drain step will always be a
   site outage. Either:
   - Add a second node so workloads can reschedule during the drain
   - Disable the system-upgrade-controller's drain behavior on this cluster
     (set `drain: { force: false, deleteEmptyDirData: false, ... }` or
     `nodes.metadata.labels` to exclude this node from the Plan selector)
   - Move baohiemxe.com to the qualityspace cluster (`170.9.8.103`), which is
     also single-node but at least the Plan there has been completing
4. **Audit the qualityspace cluster** (170.9.8.103) to make sure the same
   system-upgrade Plan is not also stuck or about to wedge.

## What I touched in repair (no rollback needed)

- `kubectl uncordon metal3-oci-control` on the baohiemxe k3s cluster. The
  system-upgrade-controller then re-ran its Plan cleanly. Node is now
  `Ready` with no `SchedulingDisabled`. The cluster is in the same state it
  would be in if the May 10 upgrade had succeeded the first time.

## Status as of writing

- `baohiemxe.com` → HTTP 200 (verified Cloudflare → cluster → pod)
- `qualityspace.com` → HTTP 200 (separate cluster, unaffected)
- `metal3-oci-control` → `Ready` on k3s v1.34.8+k3s1
- `system-upgrade/plan/k3s-server` → `Complete: True` at 2026-05-21T13:44:13Z

Author: incident debug session with Claude, Kevin Vu
Date: 2026-05-21
