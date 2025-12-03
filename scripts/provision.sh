#!/bin/bash
# Local wrapper to provision servers via the OCI Tinkerbell cluster
set -e

HARDWARE_NAME=${1:-colo-server-01}
OCI_SERVER="ubuntu@170.9.8.103"
REPO_DIR="/home/ubuntu/gitops-metal-foundry"

case "$HARDWARE_NAME" in
    colo-server-01)
        WORKFLOW_FILE="$REPO_DIR/kubernetes/infrastructure/tinkerbell/workflows.yaml"
        WORKFLOW_NAME="colo-server-01-ubuntu"
        ;;
    anvil)
        WORKFLOW_FILE="$REPO_DIR/kubernetes/infrastructure/tinkerbell/workflows.yaml"
        WORKFLOW_NAME="anvil-ubuntu"
        ;;
    *)
        echo "Unknown hardware: $HARDWARE_NAME"
        echo "Usage: $0 [colo-server-01|anvil]"
        exit 1
        ;;
esac

echo "Provisioning $HARDWARE_NAME..."
echo "Connecting to $OCI_SERVER..."

# Run the provision script on the OCI server
ssh "$OCI_SERVER" "cd $REPO_DIR && git pull && bash scripts/provision-server.sh $WORKFLOW_FILE"

echo "Provisioning complete!"
