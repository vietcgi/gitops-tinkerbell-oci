# Auto-Registration and Discovery for Tinkerbell

## The Challenge

Tinkerbell requires hardware to be pre-registered with MAC addresses before provisioning. This is different from MAAS which can auto-discover and commission unknown hardware.

## Solution: DHCP Snooping + Auto-Registration Service

We can implement a discovery service that:

1. **Monitors DHCP requests** from unknown MAC addresses
2. **Creates temporary hardware definitions** for discovery
3. **Provides a web interface** for administrators to approve machines
4. **Generates proper hardware definitions** after approval

## Implementation

### 1. DHCP Monitoring Service

```yaml
# Create a service that monitors DHCP logs
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dhcp-monitor
  namespace: tinkerbell
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dhcp-monitor
  template:
    metadata:
      labels:
        app: dhcp-monitor
    spec:
      containers:
      - name: monitor
        image: your-registry/dhcp-monitor:latest
        env:
        - name: TINKERBELL_API_URL
          value: "http://tinkerbell:42113"
        - name: KUBERNETES_NAMESPACE
          value: "tink-system"
```

### 2. Discovery Workflow Template

When an unknown MAC is detected, the service:

1. Creates a temporary hardware definition with a discovery workflow
2. The server boots and runs hardware introspection 
3. Reports back hardware specifications
4. Admin reviews and approves the machine
5. Proper workflow is assigned

### 3. Registration Web Interface

A web UI that shows:
- Recently discovered machines
- Their hardware specifications  
- Ability to approve and assign workflows
- Generate proper hardware definitions

## Alternative: Hybrid Approach

Since implementing a full discovery service is complex, here's a simpler approach that mimics MAAS commissioning:

### 1. Default Discovery Template

Use a single template that all unknown machines boot into:

```yaml
apiVersion: tinkerbell.org/v1alpha1
kind: Template
metadata:
  name: default-discovery-template
  namespace: tink-system
spec:
  # Template that introspects hardware and reports to a service
  # Then waits for manual configuration
```

### 2. Modified Smee Configuration

Configure Smee to serve the discovery template for any MAC address not specifically configured.

### 3. Webhook Integration

When hardware boots with an unknown MAC, Smee could trigger a webhook to add the MAC to a pending list.

## Recommended Implementation

For GitOps Metal Foundry, I recommend creating a "Hardware Registration" service that:

1. **Monitors unknown DHCP requests** through Tinkerbell logs or network monitoring
2. **Creates temporary hardware definitions** that boot to a discovery OS
3. **Provides a web UI** for administrators to review discovered hardware
4. **Generates proper hardware definitions** when approved
5. **Supports bulk import** of MAC addresses for large deployments

```yaml
# Example: Registration workflow
apiVersion: v1
kind: ConfigMap
metadata:
  name: discovery-config
  namespace: tinkerbell
data:
  # Script that discovers hardware and reports to registration service
  discovery-script.sh: |
    #!/bin/bash
    # Collect hardware info
    mac=$(ip link show | grep -oE 'link/ether ([0-9a-fA-F:]{17})' | head -1 | awk '{print $2}')
    
    # Create registration request
    curl -X POST http://registration-service/register \
      -H "Content-Type: application/json" \
      -d "{
        \"mac\": \"$mac\",
        \"specs\": $(lshw -json),
        \"timestamp\": \"$(date -Iseconds)\"
      }"
    
    # Wait for approval or timeout
    sleep 86400  # Wait 24 hours for admin action
```

## Operational Flow

1. **New server boots**: Server requests DHCP with unknown MAC
2. **Discovery detected**: Service notices unknown MAC in logs
3. **Hardware definition created**: Temporary definition with discovery workflow
4. **Server provisions**: Boots discovery OS, reports specs
5. **Admin review**: Web UI shows discovered hardware
6. **Approval process**: Admin approves and assigns proper workflow
7. **Production provisioning**: Server gets full OS installation

This approach provides MAAS-like functionality while working within Tinkerbell's architecture.