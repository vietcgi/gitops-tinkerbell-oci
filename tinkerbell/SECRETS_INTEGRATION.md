# Tinkerbell External Secrets Integration

This document explains how to securely manage sensitive data (SSH keys, auth tokens, etc.) in Tinkerbell without committing them to Git.

## Recommended Approach: External Secrets Operator (ESO)

The GitOps Metal Foundry project uses Sealed Secrets for sensitive data. For Tinkerbell workflows, we recommend using External Secrets Operator to fetch secrets from external secret stores.

## Setup

### 1. Create ExternalSecret for Tinkerbell parameters

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: tinkerbell-parameters
  namespace: tink-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend  # or aws-secrets-manager, azure-keyvault, etc.
    kind: SecretStore
  target:
    name: tinkerbell-secrets
    creationPolicy: Owner
  data:
  - secretKey: ssh-public-key
    remoteRef:
      key: metal-foundry-ssh-keys
      property: public-key
  - secretKey: k3s-join-token
    remoteRef:
      key: k3s-cluster-secrets
      property: join-token
  - secretKey: tailscale-auth-key
    remoteRef:
      key: tailscale-keys
      property: auth-key
```

### 2. Update Workflow to use SecretStore

You can modify the workflow template to reference secrets from Kubernetes secrets that are created by External Secrets Operator:

```yaml
apiVersion: tinkerbell.org/v1alpha1
kind: Workflow
metadata:
  name: provision-worker-01
  namespace: tink-system
spec:
  hardwareRef:
    name: worker-01
  templateRef:
    name: ubuntu-24.04-k3s
  templateParams:
    device_1: "{{.Hardware.Spec.Disks[0].Device}}"
    ssh_public_key: "{{.Secrets.tinkerbell_secrets.data.ssh_public_key}}"
    tailscale_auth_key: "{{.Secrets.tinkerbell_secrets.data.tailscale_auth_key}}"
    k3s_url: "{{.Secrets.tinkerbell_secrets.data.k3s_url}}"
    k3s_token: "{{.Secrets.tinkerbell_secrets.data.k3s_token}}"
```

## Alternative: Using Sealed Secrets

If you prefer to use the project's existing Sealed Secrets approach:

### 1. Create and seal your secrets:

```bash
# Create a Kubernetes secret
kubectl create secret generic tinkerbell-params \
  --from-literal=ssh-public-key="ssh-rsa AAAAB3NzaC1yc2E..." \
  --from-literal=k3s-join-token="K10a1b2c3d4e5f6..." \
  --from-literal=tailscale-auth-key="tskey-auth-1234567890" \
  --from-literal=k3s-url="https://10.0.1.10:6443" \
  --dry-run=client -o json > secret.json

# Seal the secret
kubeseal --format yaml < secret.json > sealed-secret.yaml

# Apply the sealed secret
kubectl apply -f sealed-secret.yaml
```

### 2. Mount the secret in your Tinkerbell template:

The template can then reference the mounted secret values instead of exposing them directly in the workflow parameters.

## Security Best Practices

1. **Never commit secrets to Git** - Always use external secret management
2. **Use environment-specific parameters** - Different environments may have different secrets
3. **Rotate secrets regularly** - Plan for regular rotation of SSH keys and tokens
4. **Audit access** - Monitor who has access to the external secret stores
5. **Validate secrets exist** - The templates now include checks for placeholder values

## Placeholder Detection

The updated templates will now detect and gracefully handle placeholder values:
- If `tailscale_auth_key` is `tskey-auth-xxx`, Tailscale setup will be skipped
- If `k3s_token` is `K3S_TOKEN_HERE`, K3s agent installation will be skipped
- If `k3s_url` is `https://10.0.1.10:6443`, K3s agent installation will be skipped

This prevents machines from being provisioned with invalid credentials and provides clear logging about what was skipped.