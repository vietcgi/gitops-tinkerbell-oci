#!/bin/bash
# Local wrapper to provision servers via the OCI Tinkerbell cluster
# Usage: ./provision.sh <hardware> [workflow]
# Examples:
#   ./provision.sh colo-server-01          # Uses colo-server-01-ubuntu workflow
#   ./provision.sh anvil                   # Uses anvil-harvester workflow (default)
#   ./provision.sh anvil ubuntu            # Uses anvil-ubuntu workflow
#   ./provision.sh anvil harvester         # Uses anvil-harvester workflow
set -e

HARDWARE_NAME=${1:-colo-server-01}
WORKFLOW_TYPE=${2:-}
OCI_SERVER="ubuntu@170.9.8.103"
REPO_DIR="/home/ubuntu/gitops-tinkerbell-oci"
WORKFLOW_FILE="$REPO_DIR/kubernetes/infrastructure/tinkerbell/workflows.yaml"

case "$HARDWARE_NAME" in
    colo-server-01)
        WORKFLOW_NAME="colo-server-01-ubuntu"
        ;;
    anvil)
        # Default to harvester for anvil, but allow override
        if [ -z "$WORKFLOW_TYPE" ] || [ "$WORKFLOW_TYPE" = "harvester" ]; then
            WORKFLOW_NAME="harvester"
        else
            WORKFLOW_NAME="anvil-$WORKFLOW_TYPE"
        fi
        ;;
    *)
        echo "Unknown hardware: $HARDWARE_NAME"
        echo "Usage: $0 <hardware> [workflow]"
        echo "  hardware: colo-server-01, anvil"
        echo "  workflow: ubuntu, harvester (optional, hardware-specific default)"
        exit 1
        ;;
esac

echo "Provisioning $HARDWARE_NAME with workflow $WORKFLOW_NAME..."
echo "Connecting to $OCI_SERVER..."

# Run the provision script on the OCI server
ssh "$OCI_SERVER" "cd $REPO_DIR && git pull && bash scripts/provision-server.sh $WORKFLOW_FILE $WORKFLOW_NAME"

echo "Provisioning complete!"
