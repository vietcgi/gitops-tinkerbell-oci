#!/bin/bash
#
# Metal Foundry - Complete Cluster Setup
#
# This script sets up a complete K3s cluster with:
#   - K3s (Kubernetes)
#   - Cilium (CNI + Ingress)
#   - Flux (GitOps)
#   - All infrastructure components via GitOps
#
# Usage:
#   sudo ./setup-cluster.sh [github-owner] [github-repo]
#
# The script is idempotent - safe to run multiple times.
#
set -euo pipefail

# Ensure HOME is set for cloud-init environments (Cilium CLI requires it)
export HOME="${HOME:-/root}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

#=============================================================================
# Configuration
#=============================================================================
GITHUB_OWNER="${1:-vietcgi}"
GITHUB_REPO="${2:-gitops-tinkerbell-oci}"
BRANCH="main"
CLUSTER_PATH="kubernetes"
REPO_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

LOG_FILE="/var/log/metal-foundry-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

#=============================================================================
# Helper Functions
#=============================================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_section() { echo ""; log "========== $* =========="; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Please run as root (sudo)"
        exit 1
    fi
}

wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}
    log "Waiting for pods with label '$label' in namespace '$namespace'..."
    kubectl wait --for=condition=ready pod -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null || true
}

#=============================================================================
# Main Installation
#=============================================================================
log_section "Metal Foundry Cluster Setup"
log "GitHub: ${GITHUB_OWNER}/${GITHUB_REPO}"
log "Branch: ${BRANCH}"

check_root

# NOTE: System tuning (sysctl, file limits, systemd limits) and chrony are now
# configured via cloud-init for faster deployment. See:
#   terraform/modules/compute/cloud-init.yaml
#
# If running this script manually (not via cloud-init), ensure these are configured:
#   - /etc/sysctl.d/99-metal-foundry.conf
#   - /etc/security/limits.d/99-metal-foundry.conf
#   - /etc/systemd/system.conf.d/99-metal-foundry.conf
#   - /etc/chrony/chrony.conf (or /etc/chrony.conf)

#-----------------------------------------------------------------------------
# Step 1: Install K3s
#-----------------------------------------------------------------------------
log_section "Step 1: K3s Installation"

if ! command -v k3s &> /dev/null; then
    log "Installing K3s..."
    # Disable: flannel (using Cilium CNI), traefik (using Cilium Gateway), servicelb (using Cilium L2)
    # Disable: network-policy (using Cilium network policies)
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable INSTALL_K3S_EXEC="server \
        --flannel-backend=none \
        --disable-network-policy \
        --disable=traefik \
        --disable=servicelb" sh -
else
    log "K3s already installed"
fi

# Wait for K3s API to be available (node won't be Ready until CNI is installed)
log "Waiting for K3s API to be available..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes &>/dev/null; do
    sleep 5
done
log "K3s API is ready (node will become Ready after CNI installation)"

#-----------------------------------------------------------------------------
# Step 2: Install Helm
#-----------------------------------------------------------------------------
log_section "Step 2: Helm Installation"

if ! command -v helm &> /dev/null; then
    log "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    log "Helm already installed: $(helm version --short)"
fi

#-----------------------------------------------------------------------------
# Step 3: Install Cilium via Helm (matches Flux HelmRelease values)
#-----------------------------------------------------------------------------
log_section "Step 3: Cilium CNI Installation"

# Install Cilium CLI (useful for debugging: cilium status, cilium connectivity test)
if ! command -v cilium &> /dev/null; then
    log "Installing Cilium CLI..."
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt 2>/dev/null || echo "v0.16.22")
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    curl -sL --fail "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz" | tar xz -C /usr/local/bin
    log "Cilium CLI installed: $(cilium version --client 2>/dev/null | head -1 || echo 'installed')"
else
    log "Cilium CLI already installed: $(cilium version --client 2>/dev/null | head -1)"
fi

# Add Cilium Helm repository
log "Adding Cilium Helm repository..."
helm repo add cilium https://helm.cilium.io/
helm repo update

# Get the latest stable Cilium version from Helm repo
CILIUM_VERSION=$(helm search repo cilium/cilium -o json 2>/dev/null | head -c 10000 | jq -r '.[0].version' 2>/dev/null) || true
if [ -z "$CILIUM_VERSION" ] || [ "$CILIUM_VERSION" = "null" ]; then
    log "Could not determine latest Cilium version, using fallback 1.18.4"
    CILIUM_VERSION="1.18.4"
fi
log "Using Cilium version: $CILIUM_VERSION"

# Install Gateway API CRDs BEFORE Cilium (required for Cilium's gateway controller to initialize)
# Cilium requires these CRDs to be pre-installed - it doesn't install them automatically
log "Installing Gateway API CRDs..."

# Get the latest Gateway API version
GATEWAY_API_VERSION=""
if command -v curl &> /dev/null; then
    # Fetch the latest release tag from GitHub API
    GATEWAY_API_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/gateway-api/releases/latest | jq -r '.tag_name' 2>/dev/null)
    if [ -z "$GATEWAY_API_VERSION" ] || [ "$GATEWAY_API_VERSION" = "null" ]; then
        log "Could not fetch latest Gateway API version, using fallback v1.2.0"
        GATEWAY_API_VERSION="v1.2.0"
    fi
else
    log "curl not available, using fallback Gateway API version v1.2.0"
    GATEWAY_API_VERSION="v1.2.0"
fi

log "Using Gateway API version: $GATEWAY_API_VERSION"

# Standard CRDs
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GATEWAY_API_VERSION/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GATEWAY_API_VERSION/config/crd/standard/gateway.networking.k8s.io_gateways.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GATEWAY_API_VERSION/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GATEWAY_API_VERSION/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GATEWAY_API_VERSION/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml"
log "Gateway API CRDs installed"

# Wait for CRDs to be established
log "Waiting for Gateway API CRDs to be established..."
kubectl wait --for condition=established --timeout=60s crd/gatewayclasses.gateway.networking.k8s.io
kubectl wait --for condition=established --timeout=60s crd/gateways.gateway.networking.k8s.io
kubectl wait --for condition=established --timeout=60s crd/httproutes.gateway.networking.k8s.io
kubectl wait --for condition=established --timeout=60s crd/grpcroutes.gateway.networking.k8s.io
log "Gateway API CRDs are ready"

# Install Cilium CNI via Helm
# Configuration matches kubernetes/infrastructure/cilium/release.yaml EXACTLY
if ! kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null | grep -q Running; then
    log "Installing Cilium CNI via Helm..."
    helm install cilium cilium/cilium --version "$CILIUM_VERSION" \
        --namespace kube-system \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost=localhost \
        --set k8sServicePort=6443 \
        --set ingressController.enabled=false \
        --set ingressController.loadbalancerMode=shared \
        --set ingressController.default=true \
        --set ingressController.hostNetwork.enabled=true \
        --set ingressController.enforceHttps=false \
        --set gatewayAPI.enabled=true \
        --set gatewayAPI.hostNetwork.enabled=true \
        --set gatewayAPI.enableAppProtocol=true \
        --set gatewayAPI.enableAlpn=true \
        --set envoy.enabled=true \
        --set envoy.securityContext.capabilities.keepCapNetBindService=true \
        --set "envoy.securityContext.capabilities.envoy={NET_BIND_SERVICE,NET_ADMIN,SYS_ADMIN}" \
        --set l2announcements.enabled=true \
        --set externalIPs.enabled=true \
        --set nodePort.enabled=true \
        --set hubble.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true \
        --set "hubble.metrics.enabled={dns,drop,tcp,flow,icmp,http}" \
        --set hubble.metrics.serviceMonitor.enabled=false \
        --set operator.replicas=1 \
        --set operator.resources.limits.cpu=100m \
        --set operator.resources.limits.memory=128Mi \
        --set operator.resources.requests.cpu=10m \
        --set operator.resources.requests.memory=64Mi \
        --set resources.limits.cpu=500m \
        --set resources.limits.memory=512Mi \
        --set resources.requests.cpu=100m \
        --set resources.requests.memory=128Mi \
        --set ipam.mode=kubernetes \
        --set bandwidthManager.enabled=true \
        --set bpf.masquerade=true \
        --set prometheus.enabled=true \
        --set prometheus.serviceMonitor.enabled=false \
        --wait \
        --timeout 10m
else
    log "Cilium already installed"
fi

# Wait for Cilium pods to be ready
log "Waiting for Cilium pods to be ready..."
kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s 2>/dev/null || true
log "Cilium is ready"

# NOTE: CiliumLoadBalancerIPPool is managed by Flux (kubernetes/infrastructure/cilium/pool.yaml)
# With hostNetwork mode, the Gateway binds directly to host ports, so LB pool is optional

# Create L2 Announcement Policy (matches kubernetes/infrastructure/cilium/release.yaml)
log "Creating CiliumL2AnnouncementPolicy..."
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-l2-policy
  namespace: kube-system
spec:
  interfaces:
    - ^eth[0-9]+
    - ^en[a-z0-9]+
    - ^ens[0-9]+
  externalIPs: true
  loadBalancerIPs: true
EOF
log "CiliumL2AnnouncementPolicy created"

# Create Cilium GatewayClass (CRDs were installed before Cilium)
log "Creating Cilium GatewayClass..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
EOF
log "Cilium GatewayClass created"

# Wait for GatewayClass to be accepted by Cilium
log "Waiting for Cilium to accept GatewayClass..."
for i in {1..30}; do
    STATUS=$(kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
    if [ "$STATUS" = "True" ]; then
        log "GatewayClass accepted by Cilium"
        break
    fi
    if [ $i -eq 30 ]; then
        log "WARNING: GatewayClass not accepted after 30s, continuing anyway"
    fi
    sleep 1
done

#-----------------------------------------------------------------------------
# Step 4: Install Flux
#-----------------------------------------------------------------------------
log_section "Step 4: Flux GitOps Installation"

# Install Flux CLI
if ! command -v flux &> /dev/null; then
    log "Installing Flux CLI..."
    curl -s https://fluxcd.io/install.sh | bash
else
    log "Flux CLI already installed: $(flux --version)"
fi

# Check if Flux is already bootstrapped
if kubectl get deployment -n flux-system source-controller &>/dev/null; then
    log "Flux already bootstrapped, triggering reconciliation..."
    flux reconcile source git flux-system || true
    flux reconcile kustomization flux-system || true
else
    log "Running Flux pre-flight checks..."
    flux check --pre

    log "Installing Flux components..."
    flux install

    log "Creating GitRepository source..."
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

    log "Creating root Kustomization..."
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
  timeout: 10m
EOF

    log "Waiting for Flux controllers (parallel)..."

    # Wait for all core controllers in parallel with a single command
    if ! kubectl wait --for=condition=available --timeout=120s \
        deployment/source-controller \
        deployment/kustomize-controller \
        deployment/helm-controller \
        deployment/notification-controller \
        -n flux-system; then
        log "ERROR: Flux controllers failed to start within timeout"
        kubectl get deployments -n flux-system
        exit 1
    fi
    log "✓ All Flux controllers are ready"

    log "Triggering initial reconciliation (async)..."

    # Trigger reconciliation without blocking - Flux handles it asynchronously
    # The GitOps controllers will continuously reconcile on their interval
    kubectl annotate --overwrite gitrepository/flux-system -n flux-system \
        reconcile.fluxcd.io/requestedAt="$(date +%s)" || true
    kubectl annotate --overwrite kustomization/flux-system -n flux-system \
        reconcile.fluxcd.io/requestedAt="$(date +%s)" || true

    log "✓ Reconciliation triggered (Flux will continue in background)"
fi

log "Flux is ready"

#-----------------------------------------------------------------------------
# Step 5: Setup User Access
#-----------------------------------------------------------------------------
log_section "Step 5: User Access Setup"

# Setup kubeconfig for ubuntu user
if id ubuntu &>/dev/null; then
    log "Setting up kubeconfig for ubuntu user..."
    mkdir -p /home/ubuntu/.kube
    cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
    sed -i 's/127.0.0.1/localhost/g' /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube
    grep -q 'KUBECONFIG' /home/ubuntu/.bashrc || echo 'export KUBECONFIG=/home/ubuntu/.kube/config' >> /home/ubuntu/.bashrc
fi

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
log_section "Setup Complete!"

echo ""
echo "Versions:"
echo "  K3s:    $(k3s --version | head -1)"
echo "  Helm:   $(helm version --short 2>/dev/null || echo 'installed')"
echo "  Cilium: $(cilium version --client 2>/dev/null | head -1 || echo 'installed')"
echo "  Flux:   $(flux --version 2>/dev/null || echo 'installed')"
echo ""
echo "Cluster Status:"
kubectl get nodes
echo ""
echo "Flux Status:"
flux get kustomizations
echo ""
echo "GitOps will now automatically deploy:"
echo "  - Sealed Secrets"
echo "  - Cert-Manager + Let's Encrypt issuers"
echo "  - Local-path storage provisioner"
echo "  - Prometheus + Grafana monitoring"
echo "  - Cilium ingress controller"
echo ""
echo "To monitor deployment progress:"
echo "  watch flux get kustomizations"
echo "  watch kubectl get helmreleases -A"
echo ""
echo "To access as ubuntu user, logout and login again, or run:"
echo "  export KUBECONFIG=/home/ubuntu/.kube/config"
echo ""
log "Setup completed at $(date)"
