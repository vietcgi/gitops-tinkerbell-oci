#!/bin/bash
set -e

WORKFLOW_FILE=$1
NAMESPACE="tink-system"
FLUX_KUSTOMIZATION="infrastructure"

if [ -z "$WORKFLOW_FILE" ]; then
    echo "Usage: $0 <workflow-yaml-file>"
    exit 1
fi

# Extract hardware name from workflow file
WORKFLOW_NAME=$(grep -A 10 "kind: Workflow" "$WORKFLOW_FILE" | grep "name:" | head -n 1 | awk '{print $2}')
HARDWARE_NAME=$(grep "hardwareRef:" "$WORKFLOW_FILE" | awk '{print $2}')

echo "Workflow: $WORKFLOW_NAME"
echo "Hardware: $HARDWARE_NAME"

# Suspend Flux to prevent it from resetting allowPXE during provisioning
echo "Suspending Flux reconciliation..."
flux suspend kustomization "$FLUX_KUSTOMIZATION" -n flux-system

# Ensure Flux is resumed on exit (success or failure)
trap 'echo "Resuming Flux reconciliation..."; flux resume kustomization "$FLUX_KUSTOMIZATION" -n flux-system' EXIT

# Enable PXE boot temporarily
echo "Enabling PXE boot for $HARDWARE_NAME..."
kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": true},
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": true}
]'

echo "Applying workflow $WORKFLOW_NAME..."
kubectl apply -f "$WORKFLOW_FILE"

echo "Waiting for workflow to start..."
sleep 5

echo "Monitoring workflow status..."
MAX_WAIT_SECONDS=1800  # 30 minutes max
START_TIME=$(date +%s)

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -gt $MAX_WAIT_SECONDS ]; then
        echo "[TIMEOUT] Workflow monitoring exceeded $MAX_WAIT_SECONDS seconds"
        echo "Disabling PXE boot..."
        kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
          {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
          {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
        ]'
        exit 1
    fi
    
    STATE=$(kubectl get workflow "$WORKFLOW_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "PENDING")
    
    if [ "$STATE" == "SUCCESS" ]; then
        echo "[SUCCESS] Workflow completed successfully!"
        break
    elif [ "$STATE" == "FAILED" ] || [ "$STATE" == "TIMEOUT" ]; then
        echo "[ERROR] Workflow failed with state: $STATE"
        echo "Disabling PXE boot to prevent reprovisioning..."
        kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
          {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
          {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
        ]'
        exit 1
    fi
    
    echo "  Current State: $STATE (elapsed: ${ELAPSED}s, checking again in 10s)..."
    sleep 10
done

# Disable PXE boot after successful provisioning
echo "Disabling PXE boot for $HARDWARE_NAME to prevent reprovisioning loop..."
kubectl patch hardware "$HARDWARE_NAME" -n "$NAMESPACE" --type=json -p='[
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
  {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
]'

echo "Cleaning up workflow..."
kubectl delete workflow "$WORKFLOW_NAME" -n "$NAMESPACE"

echo "Done! Machine should be rebooting into the new OS."
echo "Flux will resume and confirm allowPXE=false on next reconciliation."
