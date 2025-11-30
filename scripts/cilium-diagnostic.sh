#!/bin/bash
# Diagnostic script for Cilium in your K3s cluster
# Run this script after SSHing into your control plane

set -euo pipefail

echo "🔍 Cilium Diagnostic Script"
echo "==========================="

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check cluster status
echo -e "\n📊 Cluster Status:"
kubectl cluster-info
echo -e "\n📋 Node Status:"
kubectl get nodes -o wide

# Check Cilium pods specifically
echo -e "\n_Pods Status in kube-system (Cilium namespace):"
kubectl get pods -n kube-system | grep cilium || echo "No cilium pods found in kube-system"

# Check all pods to see if Cilium is in different namespace
echo -e "\n_Pods Status - All Namespaces (search for Cilium):"
kubectl get pods --all-namespaces | grep cilium || echo "No cilium pods found in any namespace"

# Check for Cilium specific namespace
if kubectl get namespace cilium-monitoring &> /dev/null; then
    echo -e "\n_Pods in cilium-monitoring namespace:"
    kubectl get pods -n cilium-monitoring
fi

# Check for Cilium operator
echo -e "\n_Pods for Cilium Operator (if exists):"
kubectl get pods -A | grep operator | grep cilium || echo "No cilium operator found"

# Check system pods
echo -e "\n_Pods in kube-system:"
kubectl get pods -n kube-system

# Check for common network plugins that might conflict with Cilium
echo -e "\n_Pods that might conflict with Cilium:"
kubectl get pods --all-namespaces | grep -E "(calico|flannel|weave|cni)" || echo "No conflicting network plugins found"

# Check services
echo -e "\n_Service Status:"
kubectl get svc --all-namespaces | grep cilium || echo "No cilium services found"

# Get more detailed information about Cilium daemonset if it exists
if kubectl get daemonset -n kube-system | grep cilium-cni &> /dev/null; then
    echo -e "\n_DaemonSet Details for Cilium CNI:"
    kubectl describe daemonset cilium-cni -n kube-system
elif kubectl get daemonset -n kube-system | grep cilium &> /dev/null; then
    echo -e "\n_DaemonSet Details for Cilium:"
    kubectl describe daemonset -n kube-system | grep cilium
fi

echo -e "\n✅ Diagnostic script complete"