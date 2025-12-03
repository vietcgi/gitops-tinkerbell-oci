#!/bin/bash
# Initialize netboot configuration for all hardware resources
# This only needs to be run once after removing netboot from hardware.yaml

NAMESPACE="tink-system"

echo "Initializing netboot configuration for hardware resources..."

# Disable PXE by default for all hardware
for hardware in colo-server-01 anvil; do
    echo "Setting allowPXE=false for $hardware..."
    kubectl patch hardware "$hardware" -n "$NAMESPACE" --type=json -p='[
      {"op": "add", "path": "/spec/interfaces/0/netboot", "value": {"allowPXE": false, "allowWorkflow": false}}
    ]' 2>/dev/null || \
    kubectl patch hardware "$hardware" -n "$NAMESPACE" --type=json -p='[
      {"op": "replace", "path": "/spec/interfaces/0/netboot/allowPXE", "value": false},
      {"op": "replace", "path": "/spec/interfaces/0/netboot/allowWorkflow", "value": false}
    ]'
done

echo "Netboot configuration initialized!"
echo "From now on, use provision-server.sh to provision servers."
