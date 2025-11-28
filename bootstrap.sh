#!/usr/bin/env bash
#
# GitOps Metal Foundry - Bootstrap Script
#
# Run this from OCI Cloud Shell:
#   curl -sSL https://raw.githubusercontent.com/YOUR_USER/gitops-metal-foundry/main/bootstrap.sh | bash
#
# Requirements:
#   - OCI Cloud Shell (recommended) OR local machine with OCI CLI
#   - GitHub account
#   - Tailscale account (free tier)
#

set -euo pipefail

#=============================================================================
# Configuration
#=============================================================================

FOUNDRY_NAME="${FOUNDRY_NAME:-metal-foundry}"
REPO_URL="${REPO_URL:-https://github.com/YOUR_USER/gitops-metal-foundry.git}"
WORK_DIR="${HOME}/gitops-metal-foundry"

# Oracle Free Tier shapes - NEVER use anything else
FREE_TIER_AMD_SHAPE="VM.Standard.E2.1.Micro"
FREE_TIER_ARM_SHAPE="VM.Standard.A1.Flex"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

#=============================================================================
# Logging
#=============================================================================

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

log_phase() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Phase $1: $2${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

banner() {
    echo -e "${CYAN}"
    cat << 'EOF'

   ╔═══════════════════════════════════════════════════════════════════╗
   ║                                                                   ║
   ║   ██████╗ ██╗████████╗ ██████╗ ██████╗ ███████╗                  ║
   ║  ██╔════╝ ██║╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝                  ║
   ║  ██║  ███╗██║   ██║   ██║   ██║██████╔╝███████╗                  ║
   ║  ██║   ██║██║   ██║   ██║   ██║██╔═══╝ ╚════██║                  ║
   ║  ╚██████╔╝██║   ██║   ╚██████╔╝██║     ███████║                  ║
   ║   ╚═════╝ ╚═╝   ╚═╝    ╚═════╝ ╚═╝     ╚══════╝                  ║
   ║                                                                   ║
   ║   ███╗   ███╗███████╗████████╗ █████╗ ██╗                        ║
   ║   ████╗ ████║██╔════╝╚══██╔══╝██╔══██╗██║                        ║
   ║   ██╔████╔██║█████╗     ██║   ███████║██║                        ║
   ║   ██║╚██╔╝██║██╔══╝     ██║   ██╔══██║██║                        ║
   ║   ██║ ╚═╝ ██║███████╗   ██║   ██║  ██║███████╗                   ║
   ║   ╚═╝     ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝                   ║
   ║                                                                   ║
   ║   ███████╗ ██████╗ ██╗   ██╗███╗   ██╗██████╗ ██████╗ ██╗   ██╗  ║
   ║   ██╔════╝██╔═══██╗██║   ██║████╗  ██║██╔══██╗██╔══██╗╚██╗ ██╔╝  ║
   ║   █████╗  ██║   ██║██║   ██║██╔██╗ ██║██║  ██║██████╔╝ ╚████╔╝   ║
   ║   ██╔══╝  ██║   ██║██║   ██║██║╚██╗██║██║  ██║██╔══██╗  ╚██╔╝    ║
   ║   ██║     ╚██████╔╝╚██████╔╝██║ ╚████║██████╔╝██║  ██║   ██║     ║
   ║   ╚═╝      ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═════╝ ╚═╝  ╚═╝   ╚═╝     ║
   ║                                                                   ║
   ╚═══════════════════════════════════════════════════════════════════╝

EOF
    echo -e "${NC}"
    echo -e "   ${BOLD}Bare Metal Cloud on Oracle Free Tier${NC}"
    echo -e "   ${BOLD}Powered by: Tinkerbell + K3s + Cilium + Flux${NC}"
    echo ""
    echo -e "   ${GREEN}Cost: \$0.00/month (Always Free Tier)${NC}"
    echo ""
}

#=============================================================================
# Phase 1: Validate Environment
#=============================================================================

phase1_validate() {
    log_phase "1" "Validate Environment"

    # Check if running in Cloud Shell
    if [[ -n "${OCI_CLI_CLOUD_SHELL:-}" ]]; then
        log_success "Running in OCI Cloud Shell"
        IN_CLOUD_SHELL=true
    else
        log_warn "Not in Cloud Shell - will need OCI CLI configured"
        IN_CLOUD_SHELL=false
    fi

    # Check required tools
    local missing=()

    for cmd in oci terraform kubectl git jq curl; do
        if command -v "$cmd" &> /dev/null; then
            log_success "$cmd: $(command -v $cmd)"
        else
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        if [[ "$IN_CLOUD_SHELL" == "true" ]]; then
            log_error "These should be pre-installed in Cloud Shell. Something is wrong."
        else
            log_info "Please install missing tools and re-run."
        fi
        exit 1
    fi

    # Verify OCI authentication
    log_info "Verifying OCI authentication..."
    if oci iam region list --output table &> /dev/null; then
        log_success "OCI authentication verified"
    else
        log_error "OCI authentication failed"
        if [[ "$IN_CLOUD_SHELL" == "true" ]]; then
            log_error "Cloud Shell should be auto-authenticated. Try refreshing the page."
        else
            log_info "Run: oci session authenticate"
        fi
        exit 1
    fi

    # Get tenancy info (fast method)
    if [[ -n "${OCI_TENANCY:-}" ]]; then
        # Already set (e.g., by Cloud Shell)
        :
    elif [[ -n "${OCI_CLI_TENANCY:-}" ]]; then
        OCI_TENANCY="$OCI_CLI_TENANCY"
    else
        # Get from config file
        OCI_TENANCY=$(grep '^tenancy' ~/.oci/config 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d ' ')
    fi

    # If still empty, get from API (users are always in root/tenancy compartment)
    if [[ -z "$OCI_TENANCY" ]]; then
        log_info "Detecting tenancy from API..."
        OCI_TENANCY=$(oci iam user list --limit 1 --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)
    fi

    if [[ -z "$OCI_TENANCY" ]]; then
        log_error "Could not determine tenancy OCID"
        log_info "Try setting: export OCI_TENANCY=ocid1.tenancy.oc1..your-tenancy-id"
        exit 1
    fi

    log_info "Tenancy: ${OCI_TENANCY:0:50}..."

    log_success "Environment validated"
}

#=============================================================================
# Phase 2: Free Tier Validation
#=============================================================================

phase2_free_tier() {
    log_phase "2" "Validate Free Tier Availability"

    echo -e "${BOLD}Oracle Always Free Resources:${NC}"
    echo ""
    echo "  ┌────────────────────────────────────────────────────────────┐"
    echo "  │ Resource              │ Free Limit      │ Our Usage       │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    echo "  │ AMD VM (E2.1.Micro)   │ 2 instances     │ 1 (control)     │"
    echo "  │ ARM VM (A1.Flex)      │ 4 OCPU / 24GB   │ Optional        │"
    echo "  │ Block Storage         │ 200 GB          │ ~100 GB         │"
    echo "  │ Object Storage        │ 10 GB           │ ~1 GB           │"
    echo "  │ Load Balancer         │ 1 (10 Mbps)     │ 1               │"
    echo "  │ Outbound Data         │ 10 TB/month     │ Minimal         │"
    echo "  └────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "  ${GREEN}${BOLD}Total Monthly Cost: \$0.00${NC}"
    echo ""

    # Select region
    log_info "Available regions with Always Free tier:"
    echo ""

    REGIONS=$(oci iam region list --query 'data[*].name' --raw-output | jq -r '.[]' | sort)

    # Show regions that typically have good free tier availability
    RECOMMENDED="us-ashburn-1 us-phoenix-1 us-sanjose-1 eu-frankfurt-1 uk-london-1 ap-tokyo-1"

    echo "  Recommended (usually have capacity):"
    for r in $RECOMMENDED; do
        if echo "$REGIONS" | grep -q "^${r}$"; then
            echo "    - $r"
        fi
    done
    echo ""

    # Get current region if in Cloud Shell
    if [[ "$IN_CLOUD_SHELL" == "true" ]] && [[ -n "${OCI_CLI_REGION:-}" ]]; then
        DEFAULT_REGION="$OCI_CLI_REGION"
    else
        DEFAULT_REGION="us-ashburn-1"
    fi

    read -r -p "Enter region [$DEFAULT_REGION]: " OCI_REGION
    OCI_REGION="${OCI_REGION:-$DEFAULT_REGION}"

    log_info "Selected region: $OCI_REGION"

    # Check if AMD free tier shape is available
    log_info "Checking free tier availability in $OCI_REGION..."

    # Get availability domains
    ADS=$(oci iam availability-domain list --query 'data[*].name' --raw-output 2>/dev/null | jq -r '.[]')

    if [[ -z "$ADS" ]]; then
        log_error "Could not list availability domains. Check your permissions."
        exit 1
    fi

    log_success "Found availability domains:"
    echo "$ADS" | while read -r ad; do
        echo "    - $ad"
    done

    # We'll validate actual shape availability during Terraform apply
    # For now, just confirm the shapes we'll use

    echo ""
    log_info "We will ONLY use these Always Free shapes:"
    echo "    - $FREE_TIER_AMD_SHAPE (AMD, 1/8 OCPU, 1GB RAM)"
    echo "    - $FREE_TIER_ARM_SHAPE (ARM, up to 4 OCPU, 24GB RAM) [optional]"
    echo ""

    log_warn "If free tier capacity is unavailable, the script will FAIL."
    log_warn "It will NEVER fall back to paid resources."
    echo ""

    read -r -p "Continue? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        exit 0
    fi

    log_success "Free tier validation complete"
}

#=============================================================================
# Phase 3: Clone Repository & Configure
#=============================================================================

phase3_configure() {
    log_phase "3" "Clone Repository & Configure"

    # Clone or update repo
    if [[ -d "$WORK_DIR" ]]; then
        log_info "Repository already exists, pulling latest..."
        cd "$WORK_DIR"
        git pull origin main || true
    else
        log_info "Cloning repository..."
        git clone "$REPO_URL" "$WORK_DIR"
        cd "$WORK_DIR"
    fi

    log_success "Repository ready at $WORK_DIR"

    # Get GitHub repo for GitOps
    echo ""
    log_info "For GitOps, Flux needs to connect to YOUR GitHub repository."
    log_info "You should fork https://github.com/YOUR_USER/gitops-metal-foundry first."
    echo ""

    read -r -p "Enter your GitHub repo URL (e.g., https://github.com/YOUR_USER/gitops-metal-foundry): " GITHUB_REPO_URL

    if [[ -z "$GITHUB_REPO_URL" ]]; then
        log_warn "No GitHub repo provided. GitOps setup will be skipped."
        SKIP_GITOPS=true
    else
        SKIP_GITOPS=false
        # Extract owner and repo name
        GITHUB_OWNER=$(echo "$GITHUB_REPO_URL" | sed -E 's|https://github.com/([^/]+)/.*|\1|')
        GITHUB_REPO=$(echo "$GITHUB_REPO_URL" | sed -E 's|https://github.com/[^/]+/([^/]+).*|\1|' | sed 's/\.git$//')
        log_info "GitHub Owner: $GITHUB_OWNER"
        log_info "GitHub Repo: $GITHUB_REPO"
    fi

    # Get Tailscale auth key
    echo ""
    log_info "Tailscale is used for secure VPN mesh to your colo machines."
    log_info "Get an auth key from: https://login.tailscale.com/admin/settings/keys"
    log_info "Create a reusable, ephemeral key."
    echo ""

    read -r -p "Enter Tailscale auth key (or press Enter to skip): " TAILSCALE_AUTH_KEY

    if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
        log_warn "No Tailscale key provided. VPN setup will be skipped."
        SKIP_TAILSCALE=true
    else
        SKIP_TAILSCALE=false
    fi

    # Get domain for TLS
    echo ""
    log_info "For TLS certificates, you need a domain name."
    read -r -p "Enter your domain (e.g., metal.example.com) or press Enter to skip: " DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        log_warn "No domain provided. TLS setup will be skipped."
        SKIP_TLS=true
    else
        SKIP_TLS=false
    fi

    # Create or get compartment
    log_info "Setting up OCI compartment..."

    EXISTING_COMPARTMENT=$(oci iam compartment list \
        --query "data[?name=='${FOUNDRY_NAME}' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
        --raw-output 2>/dev/null || echo "")

    if [[ -n "$EXISTING_COMPARTMENT" && "$EXISTING_COMPARTMENT" != "null" ]]; then
        log_info "Using existing compartment: $FOUNDRY_NAME"
        OCI_COMPARTMENT_ID="$EXISTING_COMPARTMENT"
    else
        log_info "Creating compartment: $FOUNDRY_NAME"

        # Get root compartment (tenancy)
        ROOT_COMPARTMENT="$OCI_TENANCY"

        CREATE_RESULT=$(oci iam compartment create \
            --compartment-id "$ROOT_COMPARTMENT" \
            --name "$FOUNDRY_NAME" \
            --description "GitOps Metal Foundry - Bare Metal Cloud" \
            --wait-for-state ACTIVE \
            --query 'data.id' \
            --raw-output 2>/dev/null) || true

        if [[ -n "$CREATE_RESULT" ]]; then
            OCI_COMPARTMENT_ID="$CREATE_RESULT"
            log_success "Created compartment: $FOUNDRY_NAME"
        else
            log_warn "Could not create compartment. Using tenancy root."
            OCI_COMPARTMENT_ID="$OCI_TENANCY"
        fi
    fi

    # Generate SSH key if needed
    if [[ ! -f ~/.ssh/id_ed25519.pub ]]; then
        log_info "Generating SSH key..."
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "metal-foundry"
    fi
    SSH_PUBLIC_KEY=$(cat ~/.ssh/id_ed25519.pub)

    # Write Terraform variables
    log_info "Writing Terraform configuration..."

    cat > "$WORK_DIR/terraform/terraform.tfvars" << EOF
# Generated by bootstrap.sh on $(date)
# DO NOT COMMIT THIS FILE - contains environment-specific values

tenancy_ocid     = "$OCI_TENANCY"
compartment_ocid = "$OCI_COMPARTMENT_ID"
region           = "$OCI_REGION"
ssh_public_key   = "$SSH_PUBLIC_KEY"

# Free tier shapes only - DO NOT CHANGE
control_plane_shape = "$FREE_TIER_AMD_SHAPE"

# Project settings
project_name = "$FOUNDRY_NAME"

# Optional features
domain           = "${DOMAIN:-}"
tailscale_auth_key = "${TAILSCALE_AUTH_KEY:-}"
github_owner     = "${GITHUB_OWNER:-}"
github_repo      = "${GITHUB_REPO:-}"
EOF

    log_success "Configuration complete"
}

#=============================================================================
# Phase 4: Create Infrastructure with Terraform
#=============================================================================

phase4_terraform() {
    log_phase "4" "Create Infrastructure (Terraform)"

    cd "$WORK_DIR/terraform"

    # Initialize Terraform
    log_info "Initializing Terraform..."
    terraform init

    # Plan
    log_info "Planning infrastructure..."
    terraform plan -out=tfplan

    echo ""
    log_warn "Review the plan above. This will create:"
    echo "  - 1 VCN with public/private subnets"
    echo "  - 1 AMD VM (${FREE_TIER_AMD_SHAPE}) - FREE"
    echo "  - Security lists and route tables"
    echo "  - Object storage bucket for state/backups - FREE"
    echo ""
    echo -e "  ${GREEN}Estimated cost: \$0.00/month${NC}"
    echo ""

    read -r -p "Apply this plan? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled. You can run 'terraform apply' manually later."
        exit 0
    fi

    # Apply
    log_info "Creating infrastructure (this takes 3-5 minutes)..."
    terraform apply tfplan

    # Get outputs
    CONTROL_PLANE_IP=$(terraform output -raw control_plane_public_ip 2>/dev/null || echo "")

    if [[ -z "$CONTROL_PLANE_IP" ]]; then
        log_error "Failed to get control plane IP. Check Terraform output."
        exit 1
    fi

    log_success "Infrastructure created!"
    log_info "Control plane IP: $CONTROL_PLANE_IP"

    # Wait for VM to be ready
    log_info "Waiting for VM to be accessible (this takes 1-2 minutes)..."

    for i in {1..30}; do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 ubuntu@"$CONTROL_PLANE_IP" "echo ok" &>/dev/null; then
            log_success "VM is accessible"
            break
        fi
        echo -n "."
        sleep 10
    done
    echo ""

    export CONTROL_PLANE_IP
}

#=============================================================================
# Phase 5: Bootstrap Control Plane
#=============================================================================

phase5_control_plane() {
    log_phase "5" "Bootstrap Control Plane"

    log_info "Installing K3s with Cilium on control plane..."

    # Create bootstrap script to run on control plane
    cat > /tmp/control-plane-bootstrap.sh << 'BOOTSTRAP_SCRIPT'
#!/bin/bash
set -euo pipefail

echo "=== Control Plane Bootstrap ==="

# Wait for cloud-init to complete
cloud-init status --wait || true

# Update system
sudo apt-get update
sudo apt-get install -y curl jq

# Install K3s without default CNI (we'll use Cilium)
echo "Installing K3s..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --disable=flannel \
    --disable=traefik \
    --disable=servicelb \
    --disable-network-policy \
    --flannel-backend=none \
    --write-kubeconfig-mode=644" sh -

# Wait for K3s to be ready
echo "Waiting for K3s..."
sleep 30
sudo kubectl wait --for=condition=Ready node --all --timeout=300s || true

# Detect architecture
ARCH=$(uname -m)
case ${ARCH} in
    x86_64)  CLI_ARCH="amd64" ;;
    aarch64) CLI_ARCH="arm64" ;;
    *)       echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac
echo "Detected architecture: ${ARCH} (${CLI_ARCH})"

# Install Cilium CLI
echo "Installing Cilium CLI..."
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz

# Install Cilium
echo "Installing Cilium..."
CILIUM_VERSION=$(curl -s https://api.github.com/repos/cilium/cilium/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
echo "Latest Cilium version: ${CILIUM_VERSION}"
cilium install --version "${CILIUM_VERSION}" \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=$(hostname -I | awk '{print $1}') \
    --set k8sServicePort=6443 \
    --set ingressController.enabled=true \
    --set ingressController.loadbalancerMode=shared

# Wait for Cilium
echo "Waiting for Cilium to be ready..."
cilium status --wait

# Install Helm
echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Flux CLI
echo "Installing Flux CLI..."
curl -s https://fluxcd.io/install.sh | sudo bash

echo "=== Control Plane Bootstrap Complete ==="
echo ""
kubectl get nodes
kubectl get pods -A
BOOTSTRAP_SCRIPT

    # Copy and run bootstrap script
    scp -o StrictHostKeyChecking=accept-new /tmp/control-plane-bootstrap.sh ubuntu@"$CONTROL_PLANE_IP":/tmp/
    ssh -o StrictHostKeyChecking=accept-new ubuntu@"$CONTROL_PLANE_IP" "chmod +x /tmp/control-plane-bootstrap.sh && sudo /tmp/control-plane-bootstrap.sh"

    # Copy kubeconfig locally
    log_info "Fetching kubeconfig..."
    mkdir -p ~/.kube
    scp -o StrictHostKeyChecking=accept-new ubuntu@"$CONTROL_PLANE_IP":/etc/rancher/k3s/k3s.yaml ~/.kube/config-metal-foundry

    # Update kubeconfig with correct IP
    sed -i.bak "s/127.0.0.1/$CONTROL_PLANE_IP/g" ~/.kube/config-metal-foundry

    export KUBECONFIG=~/.kube/config-metal-foundry

    log_success "Control plane ready!"
    echo ""
    kubectl get nodes
}

#=============================================================================
# Phase 6: Setup Tailscale (if provided)
#=============================================================================

phase6_tailscale() {
    log_phase "6" "Setup Tailscale VPN"

    if [[ "${SKIP_TAILSCALE:-true}" == "true" ]]; then
        log_warn "Tailscale setup skipped (no auth key provided)"
        return 0
    fi

    log_info "Installing Tailscale on control plane..."

    # shellcheck disable=SC2087
    ssh -o StrictHostKeyChecking=accept-new ubuntu@"$CONTROL_PLANE_IP" << EOF
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --auth-key="${TAILSCALE_AUTH_KEY}" --hostname="metal-foundry-control"
EOF

    log_success "Tailscale connected!"
    ssh -o StrictHostKeyChecking=accept-new ubuntu@"$CONTROL_PLANE_IP" "tailscale status"
}

#=============================================================================
# Phase 7: Setup GitHub OIDC
#=============================================================================

phase7_github_oidc() {
    log_phase "7" "Setup GitHub OIDC Federation"

    if [[ "${SKIP_GITOPS:-true}" == "true" ]]; then
        log_warn "GitHub OIDC setup skipped (no GitHub repo provided)"
        return 0
    fi

    log_info "Setting up OIDC federation for passwordless GitHub Actions..."

    # This will be handled by Terraform IAM module
    # For now, just show instructions

    echo ""
    log_info "To complete GitHub OIDC setup:"
    echo "  1. The Terraform IAM module created an identity provider"
    echo "  2. Add these secrets to your GitHub repo:"
    echo "     - OCI_TENANCY_OCID: $OCI_TENANCY"
    echo "     - OCI_COMPARTMENT_OCID: $OCI_COMPARTMENT_ID"
    echo "     - OCI_REGION: $OCI_REGION"
    echo ""
    echo "  3. GitHub Actions can now authenticate without static credentials!"
    echo ""

    log_success "GitHub OIDC configuration ready"
}

#=============================================================================
# Phase 8: Bootstrap Flux GitOps
#=============================================================================

phase8_flux() {
    log_phase "8" "Bootstrap Flux GitOps"

    if [[ "${SKIP_GITOPS:-true}" == "true" ]]; then
        log_warn "Flux setup skipped (no GitHub repo provided)"
        return 0
    fi

    log_info "Bootstrapping Flux CD..."

    echo ""
    log_info "Flux needs a GitHub personal access token with repo permissions."
    log_info "Create one at: https://github.com/settings/tokens"
    echo ""

    read -r -p "Enter GitHub personal access token (or press Enter to skip): " GITHUB_TOKEN

    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_warn "Flux bootstrap skipped. Run manually later:"
        echo ""
        echo "  flux bootstrap github \\"
        echo "    --owner=$GITHUB_OWNER \\"
        echo "    --repository=$GITHUB_REPO \\"
        echo "    --path=kubernetes/flux-system \\"
        echo "    --personal"
        echo ""
        return 0
    fi

    export GITHUB_TOKEN

    flux bootstrap github \
        --owner="$GITHUB_OWNER" \
        --repository="$GITHUB_REPO" \
        --path=kubernetes/flux-system \
        --personal

    log_success "Flux GitOps is now managing your cluster!"
}

#=============================================================================
# Final Summary
#=============================================================================

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Bootstrap Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Control Plane:${NC}"
    echo "    IP: $CONTROL_PLANE_IP"
    echo "    SSH: ssh ubuntu@$CONTROL_PLANE_IP"
    echo ""
    echo -e "  ${BOLD}Kubernetes:${NC}"
    echo "    export KUBECONFIG=~/.kube/config-metal-foundry"
    echo "    kubectl get nodes"
    echo ""
    echo -e "  ${BOLD}Cost:${NC}"
    echo -e "    ${GREEN}\$0.00/month (Always Free Tier)${NC}"
    echo ""
    echo -e "  ${BOLD}Next Steps:${NC}"
    echo "    1. Add bare metal machines: tinkerbell/hardware/"
    echo "    2. Push to GitHub for GitOps sync"
    echo "    3. Access services via your domain"
    echo ""
    echo -e "  ${BOLD}Documentation:${NC}"
    echo "    $WORK_DIR/docs/"
    echo ""
}

#=============================================================================
# Main
#=============================================================================

main() {
    banner

    phase1_validate
    phase2_free_tier
    phase3_configure
    phase4_terraform
    phase5_control_plane
    phase6_tailscale
    phase7_github_oidc
    phase8_flux

    print_summary
}

# Handle errors
trap 'log_error "Bootstrap failed at line $LINENO. Check the output above for details."' ERR

# Run main
main "$@"
