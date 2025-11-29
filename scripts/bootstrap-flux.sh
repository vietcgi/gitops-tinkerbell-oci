#!/bin/bash
#
# Bootstrap Flux GitOps on the K3s cluster
# Run this script on the control plane after K3s stack is installed
#
# Prerequisites:
#   - K3s running with kubectl access
#   - Flux CLI installed
#
# Usage:
#   ./bootstrap-flux.sh [github-owner] [github-repo]
#
set -euo pipefail

# Configuration
GITHUB_OWNER="${1:-vietcgi}"
GITHUB_REPO="${2:-gitops-metal-foundry}"
BRANCH="main"
CLUSTER_PATH="kubernetes"
REPO_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

echo "=== Flux GitOps Bootstrap ==="
echo "Started at: $(date)"
echo "GitHub: ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "Branch: ${BRANCH}"
echo "Path: ${CLUSTER_PATH}"
echo ""

# Check prerequisites
if ! command -v flux &> /dev/null; then
    echo "ERROR: flux CLI not found. Install with:"
    echo "  curl -s https://fluxcd.io/install.sh | bash"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl not found"
    exit 1
fi

# Check cluster access
if ! kubectl cluster-info &> /dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster"
    echo "Make sure KUBECONFIG is set correctly"
    exit 1
fi

# Check if Flux is already bootstrapped
if kubectl get namespace flux-system &> /dev/null; then
    echo "Flux namespace exists. Checking installation status..."
    if kubectl get deployment -n flux-system source-controller &> /dev/null; then
        echo "Flux is already bootstrapped. Running reconciliation..."
        flux reconcile source git flux-system || true
        flux reconcile kustomization flux-system || true
        echo ""
        echo "Flux status:"
        flux get all
        exit 0
    fi
fi

# Run Flux pre-check
echo "Running Flux pre-flight checks..."
flux check --pre

# Install Flux components
echo ""
echo "Installing Flux components..."
flux install

# Create GitRepository source (public repo, no auth needed)
echo ""
echo "Creating GitRepository source..."
cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  url: ${REPO_URL}
  ref:
    branch: ${BRANCH}
EOF

# Create Kustomization to sync the cluster path
echo ""
echo "Creating Kustomization..."
cat <<EOF | kubectl apply -f -
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./${CLUSTER_PATH}
  prune: true
  wait: true
  timeout: 5m
EOF

# Wait for Flux to be ready
echo ""
echo "Waiting for Flux to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/source-controller -n flux-system
kubectl wait --for=condition=available --timeout=300s deployment/kustomize-controller -n flux-system
kubectl wait --for=condition=available --timeout=300s deployment/helm-controller -n flux-system
kubectl wait --for=condition=available --timeout=300s deployment/notification-controller -n flux-system

# Trigger initial reconciliation
echo ""
echo "Triggering initial reconciliation..."
sleep 5
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# Show status
echo ""
echo "=== Flux Bootstrap Complete ==="
echo "Finished at: $(date)"
echo ""
echo "Flux components:"
flux get all
echo ""
echo "To check reconciliation status:"
echo "  flux get kustomizations"
echo "  flux get helmreleases -A"
echo ""
echo "To trigger reconciliation:"
echo "  flux reconcile kustomization flux-system --with-source"
