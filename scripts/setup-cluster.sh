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
GITHUB_REPO="${2:-gitops-metal-foundry}"
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

#-----------------------------------------------------------------------------
# Step 0: System Tuning (sysctl + limits)
#-----------------------------------------------------------------------------
log_section "Step 0: System Tuning"

log "Applying sysctl optimizations..."
cat > /etc/sysctl.d/99-metal-foundry.conf << 'EOF'
# Metal Foundry - Production System Tuning
# Based on ansible-infra common role

# Network performance - Optimized for high throughput
net.ipv4.ip_forward = 1
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10

# Multipath routing optimizations
net.ipv4.fib_multipath_hash_policy = 1
net.ipv4.fib_multipath_use_neigh = 1

# ARP cache optimizations (high-traffic environments)
net.ipv4.neigh.default.gc_thresh1 = 80000
net.ipv4.neigh.default.gc_thresh2 = 90000
net.ipv4.neigh.default.gc_thresh3 = 100000

# TCP buffer optimization (throughput for gigabit+ networks)
net.ipv4.tcp_rmem = 4096 131072 6291456
net.ipv4.tcp_wmem = 4096 16384 4194304

# Port range for high-connection scenarios
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_moderate_rcvbuf = 1

# File system optimizations
fs.file-max = 12000500
fs.nr_open = 20000500

# Security hardening
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# ICMP hardening
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Kubernetes/Cilium specific
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# Memory overcommit for Kubernetes
vm.overcommit_memory = 1
vm.panic_on_oom = 0

# Inotify limits for large clusters
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

# Load br_netfilter module for bridge settings
modprobe br_netfilter 2>/dev/null || true

# Apply sysctl settings
sysctl --system > /dev/null 2>&1 || true
log "Sysctl optimizations applied"

log "Configuring file limits..."
cat > /etc/security/limits.d/99-metal-foundry.conf << 'EOF'
# Metal Foundry - Production File Limits
# Based on ansible-infra common role

# File descriptor limits
* soft nofile 1039999
* hard nofile 1039999
root soft nofile 1039999
root hard nofile 1039999

# Process limits for high-concurrency environments
* soft nproc 9999999
* hard nproc 9999999
root soft nproc unlimited
root hard nproc unlimited

# Memory lock (for Kubernetes)
* soft memlock unlimited
* hard memlock unlimited
EOF
log "File limits configured"

# Ensure limits are applied to systemd services
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-metal-foundry.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1039999
DefaultLimitNPROC=9999999
DefaultLimitMEMLOCK=infinity
EOF
systemctl daemon-reexec 2>/dev/null || true
log "Systemd limits configured"

#-----------------------------------------------------------------------------
# Step 0b: Time Synchronization (chrony)
#-----------------------------------------------------------------------------
log_section "Step 0b: Time Synchronization"

if ! command -v chronyd &> /dev/null; then
    log "Installing chrony..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq chrony jq
    elif command -v yum &> /dev/null; then
        yum install -y chrony jq
    elif command -v dnf &> /dev/null; then
        dnf install -y chrony jq
    fi
else
    log "Chrony already installed"
fi

# Determine chrony config path (varies by distro)
if [ -d /etc/chrony ]; then
    CHRONY_CONF="/etc/chrony/chrony.conf"
else
    CHRONY_CONF="/etc/chrony.conf"
fi

# Configure chrony for accurate time sync
log "Configuring chrony at $CHRONY_CONF..."
cat > "$CHRONY_CONF" << 'EOF'
# Metal Foundry - Chrony NTP Configuration
# Use Oracle Cloud NTP servers (OCI instances)
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4

# Fallback to public NTP pools
pool time.google.com iburst maxsources 4
pool time.cloudflare.com iburst maxsources 2
pool pool.ntp.org iburst maxsources 4

# Record the rate at which the system clock gains/loses time
driftfile /var/lib/chrony/drift

# Allow the system clock to be stepped in the first three updates
makestep 1.0 3

# Enable kernel synchronization of the real-time clock (RTC)
rtcsync

# Specify directory for log files
logdir /var/log/chrony

# Enable hardware timestamping if available
hwtimestamp *
EOF

# Restart chrony to apply configuration
systemctl enable chrony
systemctl restart chrony
log "Chrony configured and running"

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

# Add Cilium Helm repository
log "Adding Cilium Helm repository..."
helm repo add cilium https://helm.cilium.io/
helm repo update

# Install Cilium CNI via Helm
# Configuration matches kubernetes/infrastructure/cilium/release.yaml EXACTLY
if ! kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null | grep -q Running; then
    log "Installing Cilium CNI via Helm..."
    helm install cilium cilium/cilium --version 1.18.4 \
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
        --set gatewayAPI.hostNetwork.enabled=false \
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

# Configure Cilium LoadBalancer IP Pool
# Create a CiliumLoadBalancerIPPool with the node's private IP so that
# LoadBalancer services and Gateways can be assigned this IP.
log "Configuring Cilium LoadBalancer IP Pool..."
PRIVATE_IP=$(curl -s --connect-timeout 5 http://169.254.169.254/opc/v1/vnics/ 2>/dev/null | jq -r '.[0].privateIp // empty' || echo "")
if [ -z "$PRIVATE_IP" ]; then
    # Fallback: get the IP from the primary interface
    PRIVATE_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "")
fi

if [ -n "$PRIVATE_IP" ]; then
    log "Node private IP: $PRIVATE_IP"
    log "Creating CiliumLoadBalancerIPPool..."
    cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: lb-pool
spec:
  blocks:
    - start: "${PRIVATE_IP}"
      stop: "${PRIVATE_IP}"
EOF
    log "CiliumLoadBalancerIPPool 'lb-pool' created with IP: $PRIVATE_IP"
else
    log "WARNING: Could not determine private IP for LoadBalancer pool"
fi

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

# Create GatewayClass for Cilium Gateway API
# This is required for Cilium to process Gateway resources
# Wait for Gateway API CRDs to be available (installed by Cilium with gatewayAPI.enabled=true)
log "Waiting for Gateway API CRDs to be available..."
until kubectl get crd gatewayclasses.gateway.networking.k8s.io &>/dev/null; do
    sleep 2
done
log "Gateway API CRDs are ready"

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

    log "Waiting for Flux controllers..."
    kubectl wait --for=condition=available --timeout=300s deployment/source-controller -n flux-system
    kubectl wait --for=condition=available --timeout=300s deployment/kustomize-controller -n flux-system
    kubectl wait --for=condition=available --timeout=300s deployment/helm-controller -n flux-system
    kubectl wait --for=condition=available --timeout=300s deployment/notification-controller -n flux-system

    log "Triggering initial reconciliation..."
    sleep 5
    flux reconcile source git flux-system
    flux reconcile kustomization flux-system
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
