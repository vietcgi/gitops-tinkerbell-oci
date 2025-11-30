# Troubleshooting Cilium Issues in GitOps Metal Foundry

When running `ssh ubuntu@170.9.13.6 "kubectl get po -A"` returns Cilium-related issues, here are the steps to diagnose and fix them:

## Common Cilium Issues

1. **Cilium Pods Not Ready**:
   ```bash
   kubectl get pods -n kube-system | grep cilium
   ```

2. **Cilium Configuration Issues**:
   ```bash
   kubectl -n kube-system logs -l k8s-app=cilium
   ```

3. **Network Policy Conflicts**:
   ```bash
   kubectl describe daemonset cilium -n kube-system
   ```

## Diagnostic Commands

Run these commands to understand the state of Cilium:

```bash
# Check all pods status
kubectl get pods -A

# Check Cilium pods specifically
kubectl get pods -n kube-system | grep cilium

# Check Cilium logs
kubectl logs -n kube-system -l k8s-app=cilium --all-containers

# Check Cilium status
kubectl exec -n kube-system ds/cilium -- cilium status

# Check cluster information
kubectl cluster-info

# Check nodes status
kubectl get nodes -o wide
```

## Quick Fix Commands

1. **Restart Cilium Pods**:
   ```bash
   kubectl delete pods -n kube-system -l k8s-app=cilium
   ```

2. **Check K3s Service Status**:
   ```bash
   sudo systemctl status k3s
   sudo journalctl -u k3s -f
   ```

3. **Reinstall Cilium (if needed)**:
   Since GitOps Metal Foundry uses Cilium as the CNI, you'll need to be careful about making changes as they may be reverted by GitOps.

## Accessing the Server

To troubleshoot directly on the server:
```bash
ssh ubuntu@170.9.13.6

# Then run kubectl commands
kubectl get pods -A
kubectl get nodes -o wide
kubectl get svc -A
```

## Checking GitOps State

Since this is a GitOps-managed cluster:
```bash
# Check if Flux is running and reconciling properly
kubectl get gitrepository,pendinghpa,helmrelease -A

# Check Flux logs
kubectl logs -n flux-system deployment/flux -f
```

## Common Solutions

1. **Wait for Reconciliation**: Sometimes pods take time to come up after initial deployment
2. **Check Resource Limits**: Ensure your VM has enough resources
3. **Check Network Connectivity**: Verify that the server can access required registries
4. **Restart K3s Service**: As a last resort, you can restart the K3s service:
   ```bash
   sudo systemctl restart k3s
   ```

## Getting More Information

If the issue persists, get additional diagnostic information:
```bash
# Collect full system information
kubectl get all -A
kubectl describe nodes
kubectl get events -A --sort-by='.lastTimestamp'
```

Remember that since you can access Grafana at https://grafana.qualityspace.com/login, the cluster is partially functional. The issue might be specific to pod-to-pod networking that Cilium handles.