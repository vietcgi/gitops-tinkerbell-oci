# Tinkerbell Provisioning Workflow

## Problem: Re-provisioning Loop

Due to using ISC DHCP (not Smee DHCP), servers will always attempt PXE boot if the DHCP server provides boot options. Even after successful provisioning, if `allowPXE: true` is set in the Hardware resource, the server will re-provision on every reboot.

## Solution: Automated PXE Toggle

The `netboot` configuration is **NOT managed by Flux** (removed from Git). Instead, the `provision-server.sh` script automatically:
1. Enables PXE before provisioning
2. Monitors the workflow
3. Disables PXE after success (or failure)

This prevents reprovisioning loops without manual Git commits.

## One-Time Setup

After deploying this configuration for the first time:

```bash
# Initialize netboot configuration (only needed once)
ssh ubuntu@170.9.8.103 "bash -s" < scripts/init-netboot.sh
```

## Provisioning a Server

Simply run the provision script - it handles everything automatically:

```bash
# From your local machine
ssh ubuntu@170.9.8.103 "kubectl apply -f - && bash /tmp/provision.sh /tmp/workflow.yaml" < <(
  cat kubernetes/infrastructure/tinkerbell/workflows.yaml
  echo "---"
  cat scripts/provision-server.sh
)

# Or if you have the repo cloned on the OCI server:
ssh ubuntu@170.9.8.103 "cd /path/to/gitops-metal-foundry && bash scripts/provision-server.sh kubernetes/infrastructure/tinkerbell/workflows.yaml"
```

## What the Script Does

1. ✅ Extracts hardware name from workflow file
2. ✅ Enables `allowPXE: true` and `allowWorkflow: true`
3. ✅ Applies the workflow
4. ✅ Monitors workflow progress (shows status every 10s)
5. ✅ On SUCCESS: Disables PXE, deletes workflow, exits with success
6. ✅ On FAILURE: Disables PXE, exits with error

## Manual Provisioning (if needed)

If you prefer manual control:

```bash
# 1. Enable PXE
kubectl patch hardware colo-server-01 -n tink-system --type=json -p='[
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": true},
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": true}
]'

# 2. Apply workflow
kubectl apply -f kubernetes/infrastructure/tinkerbell/workflows.yaml

# 3. Reboot the server
ssh root@108.181.38.85 "reboot"

# 4. Monitor
kubectl get workflow colo-server-01-ubuntu -n tink-system -o wide

# 5. After success, disable PXE
kubectl patch hardware colo-server-01 -n tink-system --type=json -p='[
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
]'
```

## Why This Works

- **Flux doesn't manage netboot**: The `netboot` field is removed from `hardware.yaml` in Git
- **Script controls PXE state**: Dynamically enables/disables based on provisioning state
- **No Git commits needed**: All state changes happen via `kubectl patch`
- **Fallback in iPXE**: If Smee returns 404 (no workflow or allowPXE=false), iPXE boots from disk

## Troubleshooting

### Server keeps re-provisioning
Check if allowPXE is still enabled:
```bash
kubectl get hardware colo-server-01 -n tink-system -o jsonpath='{.spec.interfaces[0].netboot}'
```

Should show: `{"allowPXE":false,"allowWorkflow":false}`

### Workflow stuck in PENDING
The tink-worker might not be running. Check logs:
```bash
ssh root@108.181.38.85 "nerdctl -n services.linuxkit exec hook-docker docker logs tink-worker --tail=50"
```

