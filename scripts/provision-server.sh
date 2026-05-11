#!/bin/bash
# Tinkerbell Server Provisioning Script
# Handles the kexec completion detection properly by verifying the NEW OS booted
set -e

WORKFLOW_FILE=$1
WORKFLOW_NAME_ARG=$2  # Optional: specific workflow name to provision
NAMESPACE="tink-system"
FLUX_KUSTOMIZATION="infrastructure"

# Timeouts
MAX_WORKFLOW_SECONDS=1800   # 30 minutes for workflow to reach reboot
MAX_REBOOT_OFFLINE=600      # 10 minutes for server to go offline (BIOS reboot is slow)
MAX_REBOOT_ONLINE=600       # 10 minutes for server to come back online (BIOS POST + GRUB + kernel)
MAX_VERIFY_SECONDS=300      # 5 minutes to verify new OS (cloud-init can be slow)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ -z "$WORKFLOW_FILE" ]; then
    echo "Usage: $0 <workflow-yaml-file> [workflow-name]"
    exit 1
fi

# Extract hardware name and workflow name
if [ -n "$WORKFLOW_NAME_ARG" ]; then
  # If workflow name provided as parameter, use it and get hardware from it
  WORKFLOW_NAME="$WORKFLOW_NAME_ARG"
  HARDWARE_NAME=$(kubectl get workflow "$WORKFLOW_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.hardwareRef}" 2>/dev/null || echo "")
  if [ -z "$HARDWARE_NAME" ]; then
    log_error "Could not find workflow $WORKFLOW_NAME or extract hardwareRef"
    exit 1
  fi
else
  # Extract from first document in YAML file (legacy behavior)
  FIRST_DOC=$(awk '/^---/{if(NR>1)exit}1' "$WORKFLOW_FILE")
  WORKFLOW_NAME=$(echo "$FIRST_DOC" | grep -A 10 "kind: Workflow" | grep "name:" | head -n 1 | awk '{print $2}')
  HARDWARE_NAME=$(echo "$FIRST_DOC" | grep "hardwareRef:" | awk '{print $2}')
fi

log_info "Workflow: $WORKFLOW_NAME"
log_info "Hardware: $HARDWARE_NAME"

# Get the target IP from hardware spec
TARGET_IP=$(kubectl get hardware "$HARDWARE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.interfaces[0].dhcp.ip.address}' 2>/dev/null || echo "")
if [ -z "$TARGET_IP" ]; then
    log_error "Could not get IP address from hardware $HARDWARE_NAME"
    exit 1
fi
log_info "Target IP: $TARGET_IP"

# Get expected hostname from hardware
EXPECTED_HOSTNAME=$(kubectl get hardware "$HARDWARE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.metadata.hostname}' 2>/dev/null || echo "$HARDWARE_NAME")
log_info "Expected hostname: $EXPECTED_HOSTNAME"

# Record the start time for marker verification
PROVISION_START_TIME=$(date +%s)

# Suspend Flux to prevent it from resetting allowPXE during provisioning
log_info "Suspending Flux reconciliation..."
flux suspend kustomization "$FLUX_KUSTOMIZATION" -n flux-system

# Cleanup function for all exit paths
cleanup() {
    local exit_code=$?
    log_info "Resuming Flux reconciliation..."
    flux resume kustomization "$FLUX_KUSTOMIZATION" -n flux-system || true

    # Always try to disable PXE on exit
    log_info "Ensuring PXE is disabled..."
    kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
      {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
      {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
    ]' 2>/dev/null || true

    exit $exit_code
}
trap cleanup EXIT

# Check if workflow already exists and is in a terminal state
EXISTING_STATE=$(kubectl get workflow "$WORKFLOW_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
if [ "$EXISTING_STATE" == "TIMEOUT" ] || [ "$EXISTING_STATE" == "FAILED" ] || [ "$EXISTING_STATE" == "SUCCESS" ]; then
    log_warn "Existing workflow found in terminal state: $EXISTING_STATE"
    log_info "Deleting old workflow to start fresh..."
    kubectl delete workflow "$WORKFLOW_NAME" -n "$NAMESPACE"
    sleep 2
elif [ "$EXISTING_STATE" == "RUNNING" ]; then
    log_warn "Workflow already running - deleting to start fresh..."
    kubectl delete workflow "$WORKFLOW_NAME" -n "$NAMESPACE"
    sleep 2
fi

# Enable PXE boot
log_info "Enabling PXE boot for $HARDWARE_NAME..."
kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": true},
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": true}
]'

log_info "Applying workflow $WORKFLOW_NAME..."
kubectl apply -f "$WORKFLOW_FILE"

log_info "Waiting for workflow to start..."
sleep 5

# ============================================================================
# PHASE 1: Wait for workflow to reach reboot-into-os or kexec action
# ============================================================================
log_info "Phase 1: Monitoring workflow until reboot-into-os action..."

START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [ $ELAPSED -gt $MAX_WORKFLOW_SECONDS ]; then
        log_error "Workflow timeout after ${MAX_WORKFLOW_SECONDS}s"
        exit 1
    fi

    STATE=$(kubectl get workflow "$WORKFLOW_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "PENDING")
    CURRENT_ACTION=$(kubectl get workflow "$WORKFLOW_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentState.actionName}' 2>/dev/null || echo "")

    if [ "$STATE" == "FAILED" ] || [ "$STATE" == "TIMEOUT" ]; then
        log_error "Workflow failed with state: $STATE"
        exit 1
    fi

    # Workflow completed successfully (cexec reports success before reboot terminates HookOS)
    if [ "$STATE" == "SUCCESS" ]; then
        log_success "Workflow completed with SUCCESS"
        # Disable PXE immediately to prevent re-provisioning loop on next reboot
        log_info "Disabling PXE boot to prevent re-provisioning loop..."
        kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
          {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
          {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
        ]'
        log_success "PXE disabled - server will boot from disk"
        break
    fi

    # Check if we've reached final boot step (reboot-into-os or kexec action)
    # Only match exact action names that terminate HookOS
    if [ "$STATE" == "RUNNING" ] && [[ "$CURRENT_ACTION" == "reboot-into-os" || "$CURRENT_ACTION" == *"kexec"* ]]; then
        log_success "Boot action detected ($CURRENT_ACTION)"
        # CRITICAL: Disable PXE NOW before the reboot happens, otherwise server will PXE boot back to HookOS
        log_info "Disabling PXE boot BEFORE reboot to prevent re-provisioning loop..."
        kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
          {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
          {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
        ]'
        log_success "PXE disabled - server will boot from disk after reboot"
        break
    fi

    log_info "State: $STATE | Action: $CURRENT_ACTION (${ELAPSED}s elapsed)"
    sleep 5
done

# ============================================================================
# PHASE 2: Wait for server to go OFFLINE (reboot terminates HookOS)
# PXE is already disabled at this point, so server will boot from disk
# Note: Bare metal servers (like Dell R610) do full BIOS reboot, not kexec
# Note: Server may already be offline if reboot happened before we got here
# ============================================================================
log_info "Phase 2: Waiting for server to go offline (reboot/kexec terminating HookOS)..."

# First check if server is already offline (reboot may have happened fast)
if ! nc -z -w2 "$TARGET_IP" 22 2>/dev/null; then
    log_success "Server is already offline - reboot in progress, moving to phase 3"
else
    REBOOT_START_TIME=$(date +%s)
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - REBOOT_START_TIME))

        if [ $ELAPSED -gt $MAX_REBOOT_OFFLINE ]; then
            log_error "Timeout waiting for server to go offline after ${MAX_REBOOT_OFFLINE}s"
            exit 1
        fi

        # Check if server is offline (port 22 not responding)
        if ! nc -z -w2 "$TARGET_IP" 22 2>/dev/null; then
            log_success "Server went offline - reboot initiated, moving to phase 3"
            break
        fi

        log_info "Waiting for server to go offline... (${ELAPSED}s)"
        sleep 3
    done
fi

# ============================================================================
# PHASE 3: Wait for server to come back ONLINE
# Note: Bare metal BIOS POST + GRUB + kernel boot can take several minutes
# ============================================================================
log_info "Phase 3: Waiting for server to boot into new OS..."

BOOT_START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - BOOT_START_TIME))

    if [ $ELAPSED -gt $MAX_REBOOT_ONLINE ]; then
        log_error "Timeout waiting for server to come back online after ${MAX_REBOOT_ONLINE}s"
        exit 1
    fi

    # Check if server is back online
    if nc -z -w5 "$TARGET_IP" 22 2>/dev/null; then
        log_success "Server is back online - moving to phase 4"
        break
    fi

    log_info "Waiting for server to come online... (${ELAPSED}s)"
    sleep 5
done

# Give SSH a moment to fully initialize
sleep 5

# ============================================================================
# PHASE 4: VERIFY this is the NEW OS (not HookOS or old installation)
# ============================================================================
log_info "Phase 4: Verifying the new OS booted correctly..."

VERIFY_START_TIME=$(date +%s)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - VERIFY_START_TIME))

    if [ $ELAPSED -gt $MAX_VERIFY_SECONDS ]; then
        log_error "Timeout verifying new OS after ${MAX_VERIFY_SECONDS}s"
        log_warn "Server is reachable but verification failed - manual check required"
        exit 1
    fi

    # Try to SSH and verify the system.
    # Default account on installed Ubuntu is `kevin` per templates.yaml cloud-init;
    # fall back to `ubuntu` for legacy hosts provisioned before the switch.
    SSH_USER=$(ssh $SSH_OPTS kevin@"$TARGET_IP" "echo kevin" 2>/dev/null && echo kevin || echo ubuntu)
    VERIFY_RESULT=$(ssh $SSH_OPTS "$SSH_USER"@"$TARGET_IP" "
        echo \"HOSTNAME=\$(hostname)\"
        echo \"UPTIME=\$(awk '{print int(\$1)}' /proc/uptime)\"
        echo \"OS=\$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'\"' -f2)\"
        if [ -f /var/lib/tinkerbell-provisioned ]; then
            echo \"MARKER=\$(cat /var/lib/tinkerbell-provisioned)\"
        else
            echo \"MARKER=not_found\"
        fi
        if [ -f /var/lib/cloud/instance/boot-finished ]; then
            echo \"CLOUD_INIT=finished\"
        else
            echo \"CLOUD_INIT=pending\"
        fi
    " 2>/dev/null) || {
        log_info "SSH not ready yet, retrying... (${ELAPSED}s)"
        sleep 5
        continue
    }

    # Parse the results
    ACTUAL_HOSTNAME=$(echo "$VERIFY_RESULT" | grep "^HOSTNAME=" | cut -d= -f2)
    UPTIME=$(echo "$VERIFY_RESULT" | grep "^UPTIME=" | cut -d= -f2)
    OS=$(echo "$VERIFY_RESULT" | grep "^OS=" | cut -d= -f2-)
    MARKER=$(echo "$VERIFY_RESULT" | grep "^MARKER=" | cut -d= -f2-)
    CLOUD_INIT=$(echo "$VERIFY_RESULT" | grep "^CLOUD_INIT=" | cut -d= -f2)

    log_info "Verification results:"
    log_info "  Hostname: $ACTUAL_HOSTNAME (expected: $EXPECTED_HOSTNAME)"
    log_info "  Uptime: ${UPTIME}s"
    log_info "  OS: $OS"
    log_info "  Marker: $MARKER"
    log_info "  Cloud-init: $CLOUD_INIT"

    # Verify it's the new OS:
    # 1. Hostname should match (or be close - cloud-init may still be running)
    # 2. Uptime should be low (< 10 minutes = 600 seconds)
    # 3. OS should be Ubuntu

    if [ "$UPTIME" -lt 600 ] && [[ "$OS" == *"Ubuntu"* ]]; then
        # Additional check: if marker exists and was created after we started provisioning
        if [ "$MARKER" != "not_found" ]; then
            MARKER_TIME=$(echo "$MARKER" | grep -o 'tinkerbell_provisioned=[0-9]*' | cut -d= -f2 || echo "0")
            if [ -n "$MARKER_TIME" ] && [ "$MARKER_TIME" -ge "$PROVISION_START_TIME" ]; then
                log_success "Verified: Fresh Ubuntu installation with Tinkerbell marker"
                break
            fi
        fi

        # Even without marker, if uptime is very low and it's Ubuntu, it's likely correct
        if [ "$UPTIME" -lt 300 ]; then
            log_success "Verified: Fresh Ubuntu installation (uptime: ${UPTIME}s)"
            break
        fi
    fi

    # If we got a response but it doesn't look like the new OS, wait for cloud-init
    if [ "$CLOUD_INIT" == "pending" ]; then
        log_info "Cloud-init still running, waiting... (${ELAPSED}s)"
        sleep 5
        continue
    fi

    log_warn "Verification inconclusive, retrying... (${ELAPSED}s)"
    sleep 5
done

# ============================================================================
# PHASE 5: Cleanup
# ============================================================================
log_info "Phase 5: Cleaning up..."

# Disable PXE boot (trap will also do this, but be explicit)
log_info "Disabling PXE boot for $HARDWARE_NAME..."
kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
]'

# Delete the workflow (it will be stuck in RUNNING state forever due to kexec)
log_info "Deleting workflow (stuck in RUNNING due to kexec behavior)..."
kubectl delete workflow "$WORKFLOW_NAME" -n "$NAMESPACE" 2>/dev/null || true

# Calculate total time
TOTAL_TIME=$(($(date +%s) - PROVISION_START_TIME))
MINUTES=$((TOTAL_TIME / 60))
SECONDS=$((TOTAL_TIME % 60))

log_success "=============================================="
log_success "Provisioning completed successfully!"
log_success "=============================================="
log_info "Hardware: $HARDWARE_NAME"
log_info "IP: $TARGET_IP"
log_info "Total time: ${MINUTES}m ${SECONDS}s"
log_info "Flux will resume and confirm allowPXE=false on next reconciliation."
