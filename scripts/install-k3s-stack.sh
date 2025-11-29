#!/bin/bash
#
# Install K3s, Cilium, Helm, Flux on the control plane
# Run this script on the instance after cloud-init completes
#
set -euo pipefail

LOG_FILE="/var/log/metal-foundry-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Metal Foundry Stack Installation ==="
echo "Started at: $(date)"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Install K3s if not present
if ! command -v k3s &> /dev/null; then
    echo "Installing K3s..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable INSTALL_K3S_EXEC="server" sh -
else
    echo "K3s already installed"
fi

# Wait for K3s to be ready
echo "Waiting for K3s to be ready..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes 2>/dev/null; do
    echo "Waiting for K3s..."
    sleep 5
done

# Install Helm if not present
if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "Helm already installed"
fi

# Install Cilium CLI if not present
if ! command -v cilium &> /dev/null; then
    echo "Installing Cilium CLI..."
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"
    tar xzvf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
    rm "cilium-linux-${CLI_ARCH}.tar.gz"
else
    echo "Cilium CLI already installed"
fi

# Install Cilium CNI if not present
if ! kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null | grep -q Running; then
    echo "Installing Cilium..."
    cilium install --set kubeProxyReplacement=true
else
    echo "Cilium already installed"
fi

# Wait for Cilium to be ready
echo "Waiting for Cilium to be ready..."
cilium status --wait || true

# Install Flux CLI if not present
if ! command -v flux &> /dev/null; then
    echo "Installing Flux CLI..."
    curl -s https://fluxcd.io/install.sh | bash
else
    echo "Flux CLI already installed"
fi

# Setup kubeconfig for ubuntu user
echo "Setting up kubeconfig for ubuntu user..."
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
grep -q 'KUBECONFIG' /home/ubuntu/.bashrc || echo 'export KUBECONFIG=/home/ubuntu/.kube/config' >> /home/ubuntu/.bashrc

echo ""
echo "=== Installation Complete ==="
echo "Finished at: $(date)"
echo ""
echo "Versions installed:"
echo "  K3s:    $(k3s --version | head -1)"
echo "  Helm:   $(helm version --short)"
echo "  Cilium: $(cilium version --client | head -1)"
echo "  Flux:   $(flux --version)"
echo ""
echo "Cluster status:"
kubectl get nodes
echo ""
echo "To use kubectl as ubuntu user: logout and login again, or run:"
echo "  export KUBECONFIG=/home/ubuntu/.kube/config"
