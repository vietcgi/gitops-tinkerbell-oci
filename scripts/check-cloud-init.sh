#!/bin/bash
# Check cloud-init logs to see if Cilium installation failed
# Usage: ./check-cloud-init.sh [server_ip]

set -euo pipefail

SERVER_IP="${1:-170.9.13.6}"
SSH_USER="${2:-ubuntu}"

echo "🔍 Checking cloud-init logs for Cilium installation issues"
echo "========================================================"
echo "Target server: $SSH_USER@$SERVER_IP"
echo "Time: $(date)"
echo

echo "🔍 Checking cloud-init status..."
ssh "$SSH_USER@$SERVER_IP" "sudo cloud-init status"

echo
echo "🔍 Checking cloud-init logs for errors..."
ssh "$SSH_USER@$SERVER_IP" "sudo journalctl -u cloud-init-local -u cloud-init-config -u cloud-init-final --no-pager | grep -i -E 'error|fail|cilium|install|k3s' || echo 'No error lines found in cloud-init logs'"

echo
echo "🔍 Checking full cloud-init output log..."
ssh "$SSH_USER@$SERVER_IP" "sudo cat /var/log/cloud-init-output.log | tail -100 | grep -i -E 'error|fail|cilium|install|k3s' || echo 'No error lines found in cloud-init output'"

echo
echo "🔍 Checking if setup completed successfully..."
ssh "$SSH_USER@$SERVER_IP" "cat /var/log/metal-foundry-status || echo 'Status file not found'"

echo
echo "🔍 Checking setup logs..."
ssh "$SSH_USER@$SERVER_IP" "sudo tail -50 /var/log/metal-foundry-setup.log || echo 'Setup log not found'"

echo
echo "🔍 Checking if K3s was installed successfully..."
ssh "$SSH_USER@$SERVER_IP" "sudo k3s kubectl get nodes || echo 'K3s may not be running'"

echo
echo "🔍 Checking if Cilium should have been installed based on K3s config..."
ssh "$SSH_USER@$SERVER_IP" "cat /etc/rancher/k3s/config.yaml"

echo
echo "🔍 Looking for Tailscale status (which uses similar networking)..."
ssh "$SSH_USER@$SERVER_IP" "tailscale status || echo 'Tailscale not installed or running'"