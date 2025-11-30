# Tinkerbell Auto-Registration Controller
# This is a conceptual implementation showing how to add MAAS-like functionality

## Architecture

The auto-registration system would consist of:

1. **DHCP Monitor** - Watches for unknown MAC addresses in DHCP logs
2. **Registration Service** - Creates temporary hardware definitions
3. **Approval Dashboard** - Web UI for administrators to review discovered hardware
4. **Workflow Manager** - Assigns proper workflows after approval

## Implementation Plan

### 1. DHCP Monitor Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tinkerbell-discovery-monitor
  namespace: tinkerbell
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tinkerbell-discovery-monitor
  template:
    metadata:
      labels:
        app: tinkerbell-discovery-monitor
    spec:
      containers:
      - name: monitor
        image: ghcr.io/tinkerbell/discovery-monitor:latest
        env:
        - name: TINKERBELL_GRPC_URL
          value: "tinkerbell:42113"
        - name: KUBERNETES_NAMESPACE
          value: "tink-system"
        - name: DISCOVERY_WORKFLOW_NAME
          value: "discovery-workflow"
```

### 2. Discovery Workflow

When an unknown MAC is detected:

1. Create temporary hardware definition using the self-register template
2. The server boots to discovery mode and reports its specifications
3. Specifications are stored for admin review

### 3. Registration Dashboard

A web interface that allows administrators to:
- View discovered hardware 
- Approve/reject machines
- Assign proper workflows
- Set disk configurations
- Approve SSH keys and network settings

## Configuration

### Default Discovery Configuration

For unknown MAC addresses, the system automatically:

```yaml
apiVersion: tinkerbell.org/v1alpha1
kind: Hardware
metadata:
  name: temp-discovered-<mac-address>
  namespace: tink-system
  annotations:
    auto-generated: "true"
    discovery-timeout: "24h"
spec:
  id: "temp-discovered-<uuid>"
  metadata:
    facility:
      facility_code: "discovery"
    instance:
      hostname: "discovered-<mac-truncated>"
  network:
    interfaces:
      - dhcp:
          mac: "<actual-mac-from-request>"
          hostname: "discovered-<mac-truncated>"
  disks:
    - device: "/dev/sda"  # Default assumption
```

## Operational Workflow

1. **Server boots** with unknown MAC address
2. **DHCP request detected** by monitoring service
3. **Temporary hardware definition** created automatically
4. **Discovery workflow** assigned to MAC
5. **Server boots to discovery OS** and reports specs
6. **Admin reviews** specifications in dashboard
7. **Admin approves** and assigns proper configuration
8. **Permanent hardware definition** created
9. **Production workflow** assigned
10. **Server reboots** and gets production OS

## Security Considerations

- **Automatic discovery** is limited to specific network segments
- **Time-limited** temporary hardware definitions (auto-cleanup)
- **Admin approval required** before production deployment
- **Audit logging** of all auto-registered hardware

## Integration with GitOps Metal Foundry

This system would integrate with the existing GitOps flow:
- Auto-registered hardware definitions stored in Git
- Admin approvals trigger Git commits
- Flux applies changes automatically
- Full audit trail maintained

This provides the MAAS-like experience while maintaining GitOps principles.