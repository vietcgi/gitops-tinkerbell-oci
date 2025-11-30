#!/bin/bash
# Cilium debugging script for the specific issue
# Usage: ./debug-cilium.sh [server_ip]

set -euo pipefail

SERVER_IP="${1:-170.9.13.6}"
SSH_USER="${2:-ubuntu}"

echo "🐛 Cilium Debugging Script"
echo "==========================="
echo "Target server: $SSH_USER@$SERVER_IP"
echo "Time: $(date)"
echo

echo "🔍 Testing basic SSH connectivity..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_USER@$SERVER_IP" "echo 'SSH connected successfully'"; then
    echo "✅ SSH connection successful"
else
    echo "❌ SSH connection failed"
    exit 1
fi

echo
echo "🔍 Testing kubectl command that's causing issues..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get po -A" 2>&1 || echo "❌ Command failed as expected"

echo
echo "🔍 Checking cluster status..."
ssh "$SSH_USER@$SERVER_IP" "kubectl cluster-info"

echo
echo "🔍 Checking node status..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get nodes -o wide"

echo
echo "🔍 Checking if k3s service is running..."
ssh "$SSH_USER@$SERVER_IP" "sudo systemctl status k3s --no-pager -l"

echo
echo "🔍 Looking for Cilium pods..."
CILIUM_PODS=$(ssh "$SSH_USER@$SERVER_IP" "kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.labels[\"k8s-app\"]? == \"cilium\") | \"\\(.metadata.namespace)/\\(.metadata.name)\"' 2>/dev/null")

if [ -n "$CILIUM_PODS" ]; then
    echo "✅ Found Cilium pods:"
    echo "$CILIUM_PODS"
    
    echo
    echo "🔍 Getting Cilium pod details and logs..."
    for pod in $CILIUM_PODS; do
        namespace=$(echo "$pod" | cut -d'/' -f1)
        pod_name=$(echo "$pod" | cut -d'/' -f2)
        echo
        echo "--- Pod: $pod ---"
        ssh "$SSH_USER@$SERVER_IP" "kubectl describe pod $pod_name -n $namespace"
        echo
        echo "Logs for $pod:"
        ssh "$SSH_USER@$SERVER_IP" "kubectl logs $pod_name -n $namespace --all-containers"
    done
else
    echo "❌ No Cilium pods found - Cilium may not be installed or running"
    
    echo
    echo "🔍 Checking for any pods in kube-system namespace..."
    ssh "$SSH_USER@$SERVER_IP" "kubectl get pods -n kube-system"
    
    echo
    echo "🔍 Looking for CNI-related pods..."
    ssh "$SSH_USER@$SERVER_IP" "kubectl get pods --all-namespaces | grep -i cni || echo 'No CNI pods found'"
fi

echo
echo "🔍 Checking system resources..."
ssh "$SSH_USER@$SERVER_IP" "free -h && df -h"

echo
echo "🔍 Checking if Cilium is installed via kubectl..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get all -A | grep cilium || echo 'No Cilium resources found'"

echo
echo "🔍 Checking running processes for Cilium..."
ssh "$SSH_USER@$SERVER_IP" "ps aux | grep cilium || echo 'No Cilium processes found'"

echo
echo "🔍 Checking K3s configuration for disabled components..."
ssh "$SSH_USER@$SERVER_IP" "cat /etc/rancher/k3s/config.yaml 2>/dev/null || echo 'Config file not found'"

echo
echo "🔍 Checking if kube-proxy was disabled (as per your setup)..."
ssh "$SSH_USER@$SERVER_IP" "systemctl status kube-proxy 2>/dev/null || echo 'kube-proxy not running (expected for Cilium setup)'"

echo
echo "🔍 Done with diagnostics"
echo "If Cilium is not running, you may need to check if it was disabled or failed to install properly."