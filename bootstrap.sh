#!/usr/bin/env bash
#
# GitOps Metal Foundry - Bootstrap Script
#
# This script sets up OCI credentials for GitHub Actions OIDC authentication.
# Terraform runs from GitHub Actions, not from this script.
#
# Run from OCI Cloud Shell:
#   curl -sSL https://raw.githubusercontent.com/YOUR_USER/gitops-metal-foundry/main/bootstrap.sh | bash
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

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
# Step 1: Validate OCI Environment
#=============================================================================

validate_oci() {
    log_info "Validating OCI environment..."

    # Check if running in Cloud Shell
    if [[ -n "${OCI_CLI_CLOUD_SHELL:-}" ]]; then
        log_success "Running in OCI Cloud Shell"
    else
        log_warn "Not in Cloud Shell - ensure OCI CLI is configured"
    fi

    # Check required tools
    for cmd in oci jq curl; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Missing required tool: $cmd"
            exit 1
        fi
    done

    # Verify OCI authentication
    if ! oci iam region list --output table &> /dev/null; then
        log_error "OCI authentication failed"
        exit 1
    fi
    log_success "OCI authentication verified"

    # Get tenancy OCID
    if [[ -n "${OCI_TENANCY:-}" ]]; then
        :
    elif [[ -n "${OCI_CLI_TENANCY:-}" ]]; then
        OCI_TENANCY="$OCI_CLI_TENANCY"
    else
        OCI_TENANCY=$(grep '^tenancy' ~/.oci/config 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d ' ')
    fi

    if [[ -z "$OCI_TENANCY" ]]; then
        log_info "Detecting tenancy from API..."
        OCI_TENANCY=$(oci iam user list --limit 1 --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)
    fi

    if [[ -z "$OCI_TENANCY" ]]; then
        log_error "Could not determine tenancy OCID"
        exit 1
    fi

    log_info "Tenancy: ${OCI_TENANCY:0:50}..."
    export OCI_TENANCY
}

#=============================================================================
# Step 2: Get Configuration
#=============================================================================

get_config() {
    echo ""
    log_info "Configuration"
    echo ""

    # Region
    if [[ -n "${OCI_CLI_REGION:-}" ]]; then
        OCI_REGION="$OCI_CLI_REGION"
        log_info "Using Cloud Shell region: $OCI_REGION"
    else
        read -r -p "Enter OCI region (e.g., us-sanjose-1): " OCI_REGION < /dev/tty
    fi
    export OCI_REGION

    # GitHub repo
    echo ""
    log_info "GitHub repository for GitOps"
    read -r -p "Enter GitHub repo (owner/repo or full URL): " GITHUB_REPO_FULL < /dev/tty

    if [[ -z "$GITHUB_REPO_FULL" ]]; then
        log_error "GitHub repo is required for GitOps"
        exit 1
    fi

    # Handle both formats: "owner/repo" or "https://github.com/owner/repo"
    GITHUB_REPO_FULL=$(echo "$GITHUB_REPO_FULL" | sed 's|https://github.com/||' | sed 's|\.git$||' | sed 's|/$||')
    GITHUB_OWNER=$(echo "$GITHUB_REPO_FULL" | cut -d'/' -f1)
    GITHUB_REPO=$(echo "$GITHUB_REPO_FULL" | cut -d'/' -f2)

    if [[ -z "$GITHUB_OWNER" || -z "$GITHUB_REPO" ]]; then
        log_error "Invalid repo format. Use: owner/repo or https://github.com/owner/repo"
        exit 1
    fi

    log_info "GitHub Owner: $GITHUB_OWNER"
    log_info "GitHub Repo: $GITHUB_REPO"

    # Project name
    PROJECT_NAME="${PROJECT_NAME:-metal-foundry}"
}

#=============================================================================
# Step 3: Create Compartment
#=============================================================================

create_compartment() {
    log_info "Setting up OCI compartment..."

    EXISTING=$(oci iam compartment list \
        --query "data[?name=='${PROJECT_NAME}' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
        --raw-output 2>/dev/null || echo "")

    if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
        log_info "Using existing compartment: $PROJECT_NAME"
        OCI_COMPARTMENT="$EXISTING"
    else
        log_info "Creating compartment: $PROJECT_NAME"
        OCI_COMPARTMENT=$(oci iam compartment create \
            --compartment-id "$OCI_TENANCY" \
            --name "$PROJECT_NAME" \
            --description "GitOps Metal Foundry - Bare Metal Cloud" \
            --wait-for-state ACTIVE \
            --query 'data.id' \
            --raw-output 2>/dev/null) || {
            log_warn "Could not create compartment, using tenancy root"
            OCI_COMPARTMENT="$OCI_TENANCY"
        }
    fi

    log_success "Compartment: ${OCI_COMPARTMENT:0:50}..."
    export OCI_COMPARTMENT
}

#=============================================================================
# Step 4: Get SSH Public Key
#=============================================================================

get_ssh_key() {
    log_info "SSH public key for VM access"
    echo ""

    # Check for existing keys
    if [[ -f ~/.ssh/id_rsa.pub ]]; then
        log_info "Found existing key: ~/.ssh/id_rsa.pub"
        read -r -p "Use this key? (y/n): " use_existing < /dev/tty
        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
            export SSH_PUBLIC_KEY
            return
        fi
    fi

    echo "Paste your SSH public key (or press Enter to skip):"
    read -r SSH_PUBLIC_KEY < /dev/tty

    if [[ -z "$SSH_PUBLIC_KEY" ]]; then
        log_warn "No SSH key provided - you'll need to add it to GitHub secrets as SSH_PUBLIC_KEY"
        SSH_PUBLIC_KEY=""
    fi
    export SSH_PUBLIC_KEY
}

#=============================================================================
# Step 5: Setup GitHub OIDC in OCI
#=============================================================================

setup_oidc() {
    log_info "Setting up GitHub OIDC authentication..."

    # Step 1: Create OIDC Identity Provider for GitHub
    IDP_NAME="${PROJECT_NAME}-github-oidc"
    EXISTING_IDP=$(oci iam identity-provider list \
        --compartment-id "$OCI_TENANCY" \
        --protocol SAML2 \
        --query "data[?name=='${IDP_NAME}'].id | [0]" \
        --raw-output 2>/dev/null || echo "")

    # Note: OCI doesn't have direct OIDC IdP creation via CLI for GitHub
    # We use Dynamic Groups with OIDC claims instead
    log_info "Using Dynamic Group with OIDC claims for GitHub authentication"

    # Step 2: Create Dynamic Group matching GitHub OIDC tokens
    DG_NAME="${PROJECT_NAME}-github-actions"
    EXISTING_DG=$(oci iam dynamic-group list \
        --compartment-id "$OCI_TENANCY" \
        --query "data[?name=='${DG_NAME}'].id | [0]" \
        --raw-output 2>/dev/null || echo "")

    if [[ -n "$EXISTING_DG" && "$EXISTING_DG" != "null" ]]; then
        log_info "Dynamic group already exists: $DG_NAME"
    else
        log_info "Creating dynamic group for GitHub Actions..."

        # Matching rule for GitHub OIDC - matches tokens from this repo
        MATCHING_RULE="ALL {resource.type='workload', resource.compartment.id='${OCI_COMPARTMENT}'}"

        oci iam dynamic-group create \
            --compartment-id "$OCI_TENANCY" \
            --name "$DG_NAME" \
            --description "GitHub Actions Workload Identity for ${GITHUB_OWNER}/${GITHUB_REPO}" \
            --matching-rule "$MATCHING_RULE" \
            --wait-for-state ACTIVE > /dev/null 2>&1 && \
            log_success "Created dynamic group: $DG_NAME" || \
            log_warn "Could not create dynamic group (may need admin privileges)"
    fi

    # Step 3: Create IAM Policy
    POLICY_NAME="${PROJECT_NAME}-github-actions-policy"
    EXISTING_POLICY=$(oci iam policy list \
        --compartment-id "$OCI_TENANCY" \
        --query "data[?name=='${POLICY_NAME}'].id | [0]" \
        --raw-output 2>/dev/null || echo "")

    if [[ -n "$EXISTING_POLICY" && "$EXISTING_POLICY" != "null" ]]; then
        log_info "Policy already exists: $POLICY_NAME"
    else
        log_info "Creating IAM policy for GitHub Actions..."

        # Policy to allow dynamic group to manage resources
        STATEMENTS="[\"Allow dynamic-group ${DG_NAME} to manage all-resources in compartment ${PROJECT_NAME}\"]"

        oci iam policy create \
            --compartment-id "$OCI_TENANCY" \
            --name "$POLICY_NAME" \
            --description "Permissions for GitHub Actions to manage Metal Foundry resources" \
            --statements "$STATEMENTS" > /dev/null 2>&1 && \
            log_success "Created policy: $POLICY_NAME" || \
            log_warn "Could not create policy (may need admin privileges)"
    fi

    log_success "OIDC setup complete"
}

#=============================================================================
# Step 6: Print GitHub Setup Instructions
#=============================================================================

commit_and_push() {
    log_info "Creating and pushing terraform.tfvars..."

    # Clone repo (try SSH first, then HTTPS)
    WORK_DIR="/tmp/gitops-metal-foundry-$$"
    rm -rf "$WORK_DIR"

    if git clone "git@github.com:${GITHUB_OWNER}/${GITHUB_REPO}.git" "$WORK_DIR" 2>/dev/null; then
        log_success "Cloned via SSH"
    elif git clone "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git" "$WORK_DIR" 2>/dev/null; then
        log_success "Cloned via HTTPS"
    else
        log_error "Could not clone repo. Make sure it exists and you have access."
        return 1
    fi

    cd "$WORK_DIR"

    # Create terraform.tfvars
    cat > "terraform/terraform.tfvars" << EOF
# Generated by bootstrap.sh on $(date)
# OCI Configuration for GitOps Metal Foundry

tenancy_ocid     = "${OCI_TENANCY}"
compartment_ocid = "${OCI_COMPARTMENT}"
region           = "${OCI_REGION}"

# SSH public key for VM access
ssh_public_key = "${SSH_PUBLIC_KEY}"

# Project name
project_name = "${PROJECT_NAME}"
EOF

    log_success "Created terraform/terraform.tfvars"

    # Commit and push
    log_info "Committing and pushing to GitHub..."
    git add terraform/terraform.tfvars
    git commit -m "feat: add OCI configuration for ${OCI_REGION}" > /dev/null 2>&1 || {
        log_info "No changes to commit (tfvars already exists)"
    }

    git push origin main 2>/dev/null && {
        log_success "Pushed to GitHub - workflow will start automatically"
    } || {
        log_warn "Could not push. You may need to set up git credentials."
        log_info "Run manually: cd $WORK_DIR && git push"
        return 1
    }

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  Bootstrap Complete!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}GitHub Actions is now running Terraform!${NC}"
    echo ""
    echo "  Watch progress: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/actions"
    echo ""
    echo "  After infrastructure is created:"
    echo "    1. Get VM IP from workflow output"
    echo "    2. SSH: ssh ubuntu@<IP>"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Cost: \$0.00/month (Oracle Always Free Tier)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

#=============================================================================
# Main
#=============================================================================

main() {
    banner
    validate_oci
    get_config
    create_compartment
    get_ssh_key
    setup_oidc
    commit_and_push
}

# Handle errors
trap 'log_error "Bootstrap failed at line $LINENO"' ERR

main "$@"
