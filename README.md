# GitOps Metal Foundry

A fully automated, self-bootstrapping bare metal cloud running on **Oracle Free Tier**.

**Cost: $0.00/month** - Uses only Always Free resources.

## Features

- **100% Free** - Runs entirely on Oracle Cloud Always Free tier
- **100% GitOps** - All configuration stored in Git, changes via pull requests
- **Zero Secrets** - Uses OIDC federation for passwordless authentication
- **Cross-Platform** - Bootstrap from any browser via OCI Cloud Shell
- **Bare Metal Ready** - Provision physical servers at your colo/home lab
- **Production Grade** - K3s, Cilium, Flux, cert-manager, and more

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GitHub Repository                             │
│                   (Single Source of Truth)                           │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ OIDC (passwordless)
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Oracle Cloud Free Tier ($0/month)                 │
│                                                                      │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │           Control Plane VM (1GB RAM - FREE)                 │   │
│   │                                                              │   │
│   │   K3s │ Cilium │ Flux │ Tinkerbell │ Tailscale             │   │
│   └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ Tailscale VPN
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Your Bare Metal Servers                           │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│   │ Colo Server  │  │ Home Server  │  │ Edge Device  │              │
│   │   (K3s)      │  │   (K3s)      │  │   (K3s)      │              │
│   └──────────────┘  └──────────────┘  └──────────────┘              │
└─────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Oracle Cloud account ([sign up free](https://www.oracle.com/cloud/free/))
- GitHub account
- Tailscale account ([sign up free](https://tailscale.com/))

### Bootstrap (5 minutes)

1. **Fork this repository** to your GitHub account

2. **Open OCI Cloud Shell:**
   - Log into [Oracle Cloud Console](https://cloud.oracle.com)
   - Click the Cloud Shell icon (>_) in the top right

3. **Run the bootstrap:**
   ```bash
   curl -sSL https://raw.githubusercontent.com/YOUR_USER/gitops-metal-foundry/main/bootstrap.sh | bash
   ```

4. **Follow the prompts** for:
   - Region selection
   - GitHub repository URL
   - Tailscale auth key
   - Domain name (optional)

5. **Done!** Your control plane is running.

## What Gets Deployed

### Control Plane (Oracle Free Tier)

| Component | Purpose |
|-----------|---------|
| **K3s** | Lightweight Kubernetes |
| **Cilium** | eBPF networking, load balancing, ingress |
| **Flux CD** | GitOps continuous deployment |
| **Tinkerbell** | Bare metal provisioning |
| **Tailscale** | VPN mesh to colo/home lab |
| **cert-manager** | TLS certificate automation |
| **Sealed Secrets** | GitOps-safe secret management |

### Free Tier Resources Used

| Resource | Limit | Usage |
|----------|-------|-------|
| AMD VM | 2 VMs | 1 (control plane) |
| Storage | 200 GB | ~100 GB |
| Bandwidth | 10 TB/mo | Minimal |

**Monthly cost: $0.00**

## Adding Bare Metal Servers

1. **Register hardware** in `tinkerbell/hardware/`:
   ```yaml
   apiVersion: tinkerbell.org/v1alpha1
   kind: Hardware
   metadata:
     name: my-server
   spec:
     network:
       interfaces:
         - dhcp:
             mac: "00:00:00:00:00:01"  # Your server's MAC
   ```

2. **Create boot media:**
   ```bash
   cd boot-media
   make usb TINKERBELL_URL=https://tinkerbell.yourdomain.com
   ```

3. **Boot the server** from USB/ISO

4. **Watch it provision** automatically and join the cluster

## GitHub Actions CI/CD (OIDC - No Static Secrets)

This project uses **OIDC (OpenID Connect)** for passwordless authentication from GitHub Actions to Oracle Cloud. No API keys or secrets are stored.

**How it works:**
```
GitHub Actions                              OCI
     │                                       │
     │ 1. Request JWT (signed by GitHub)     │
     ├──────────────────────────────────────►│
     │                                       │
     │ 2. Validate JWT + match Dynamic Group │
     │◄──────────────────────────────────────┤
     │                                       │
     │ 3. Terraform apply with temp creds    │
     ├──────────────────────────────────────►│
```

**Setup (after bootstrap):**

Add these as **GitHub Repository Variables** (not secrets):

| Variable | Value |
|----------|-------|
| `OCI_TENANCY` | Your tenancy OCID |
| `OCI_COMPARTMENT` | Your compartment OCID |
| `OCI_REGION` | e.g., `us-ashburn-1` |

These are public identifiers - the OIDC token provides authentication.

## Directory Structure

```
gitops-metal-foundry/
├── bootstrap.sh           # One-command setup
├── terraform/             # OCI infrastructure
├── kubernetes/            # Flux-managed K8s manifests
│   ├── infrastructure/   # Core components
│   └── apps/             # Your applications
├── tinkerbell/           # Bare metal configs
│   ├── hardware/         # Machine definitions
│   ├── templates/        # OS templates
│   └── workflows/        # Provisioning workflows
└── boot-media/           # iPXE boot image builder
```

## Documentation

- [Architecture](docs/architecture.md)
- [Adding Bare Metal](docs/adding-bare-metal.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Cilium Troubleshooting](docs/cilium-troubleshooting.md)
- [Cilium Debugging Scripts](docs/cilium-troubleshooting.md)

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

MIT License - see [LICENSE](LICENSE)

## Acknowledgments

- [Tinkerbell](https://tinkerbell.org/) - Bare metal provisioning
- [K3s](https://k3s.io/) - Lightweight Kubernetes
- [Cilium](https://cilium.io/) - eBPF networking
- [Flux CD](https://fluxcd.io/) - GitOps toolkit
- [Tailscale](https://tailscale.com/) - Zero-config VPN
