#!/bin/bash
# Fix Cilium issues script - attempts to resolve common problems
# Usage: ./fix-cilium.sh [server_ip]

set -euo pipefail

SERVER_IP="${1:-170.9.13.6}"
SSH_USER="${2:-ubuntu}"

echo "🔧 Attempting to fix Cilium issues"
echo "================================="
echo "Target server: $SSH_USER@$SERVER_IP"
echo "Time: $(date)"
echo

echo "⚠️  WARNING: This script will attempt to fix Cilium issues."
echo "This may involve restarting services or reinstalling Cilium."
read -p "Do you want to proceed? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Operation cancelled."
    exit 0
fi

echo
echo "🔍 Checking current cluster state..."
CLUSTER_STATUS=$(ssh "$SSH_USER@$SERVER_IP" "kubectl cluster-info 2>&1" || echo "Cluster not responding")
echo "Cluster status: $CLUSTER_STATUS"

echo
echo "🔄 Restarting K3s service (this may restart Cilium)..."
ssh "$SSH_USER@$SERVER_IP" "sudo systemctl restart k3s"

echo "⏳ Waiting 30 seconds for services to restart..."
sleep 30

echo
echo "🔍 Checking if pods are now running..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get pods -A" 2>&1 || echo "Still having issues with kubectl"

echo
echo "🔍 Checking node status..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get nodes -o wide"

echo
echo "🔍 Checking for Cilium pods specifically..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get pods -A | grep cilium || echo 'No Cilium pods found yet'"

echo
echo "🔍 If Cilium is still not running, checking K3s config..."
K3S_CONFIG=$(ssh "$SSH_USER@$SERVER_IP" "cat /etc/rancher/k3s/config.yaml")
echo "Current K3s config:"
echo "$K3S_CONFIG"

echo
echo "🔍 Checking if Cilium was disabled in the config (which shouldn't happen in this setup)..."
if echo "$K3S_CONFIG" | grep -i disable | grep -i cilium; then
    echo "❌ Cilium appears to be disabled in config - this is unexpected"
    echo "The Metal Foundry setup should use Cilium as the CNI"
else
    echo "✅ Cilium doesn't appear to be disabled in the config"
fi

echo
echo "🔍 Checking if kube-proxy is disabled (should be for Cilium setup)..."
if ssh "$SSH_USER@$SERVER_IP" "systemctl is-active --quiet kube-proxy 2>/dev/null"; then
    echo "⚠️  Kube-proxy is running, but shouldn't be with Cilium setup"
    echo "This might be causing conflicts"
    ssh "$SSH_USER@$SERVER_IP" "sudo systemctl stop kube-proxy || echo 'Failed to stop kube-proxy'"
else
    echo "✅ Kube-proxy is not running (expected for Cilium setup)"
fi

echo
echo "🔍 If cluster is in bad state, we might need to reset and reinstall K3s with Cilium..."
echo "This is a more drastic measure and should be used carefully."
echo
read -p "Do you want to try resetting K3s? (yes/no): " reset_confirm

if [ "$reset_confirm" = "yes" ]; then
    echo "🔄 Resetting K3s cluster (this will destroy current cluster state)..."
    
    # Stop K3s
    ssh "$SSH_USER@$SERVER_IP" "sudo systemctl stop k3s && sudo k3s-killall.sh"
    
    # Remove data directory
    ssh "$SSH_USER@$SERVER_IP" "sudo rm -rf /var/lib/rancher/k3s"
    
    # Restart K3s with the proper config
    echo "🔄 Restarting K3s service..."
    ssh "$SSH_USER@$SERVER_IP" "sudo systemctl start k3s"
    
    # Wait for startup
    echo "⏳ Waiting for cluster to restart (60 seconds)..."
    sleep 60
    
    # Check if it's working
    echo "🔍 Checking if cluster is working now..."
    ssh "$SSH_USER@$SERVER_IP" "kubectl get nodes"
fi

echo
echo "✅ Cilium fixing attempt completed"
echo "Check if your original command now works:"
echo "ssh $SSH_USER@$SERVER_IP \"kubectl get po -A\""