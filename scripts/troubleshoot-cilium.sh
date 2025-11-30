#!/bin/bash
# Script to run kubectl command and troubleshoot Cilium issues
# Usage: ./troubleshoot-cilium.sh [server_ip]

set -euo pipefail

SERVER_IP="${1:-170.9.13.6}"
SSH_USER="${2:-ubuntu}"

echo "🔍 Troubleshooting Cilium on server: $SSH_USER@$SERVER_IP"
echo "====================================================="

# First, try the command that's having issues
echo -e "\n📋 Running: kubectl get po -A"
ssh "$SSH_USER@$SERVER_IP" "kubectl get po -A" || echo -e "\n❌ Command failed - this is expected if there are Cilium issues"

echo -e "\n🔍 Checking cluster status..."
ssh "$SSH_USER@$SERVER_IP" "kubectl cluster-info"

echo -e "\n🔍 Checking node status..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get nodes -o wide"

echo -e "\n🔍 Checking for Cilium pods..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get pods -n kube-system | grep cilium || kubectl get pods --all-namespaces | grep cilium"

echo -e "\n🔍 Checking system pods..."
ssh "$SSH_USER@$SERVER_IP" "kubectl get pods -n kube-system"

echo -e "\n🔍 Checking Cilium logs (if pods exist)..."
ssh "$SSH_USER@$SERVER_IP" "kubectl logs -n kube-system -l k8s-app=cilium --all-containers | tail -20 || echo 'No Cilium logs found'"

echo -e "\n🔧 If Cilium pods are not running, you might need to restart them:"
echo "ssh $SSH_USER@$SERVER_IP \"kubectl delete pods -n kube-system -l k8s-app=cilium\""

echo -e "\n🔧 Or restart the K3s service if needed:"
echo "ssh $SSH_USER@$SERVER_IP \"sudo systemctl restart k3s\""

echo -e "\n📝 You mentioned Grafana is accessible at https://grafana.qualityspace.com/login"
echo "This suggests the cluster is partially functional but there might be CNI/pod networking issues."