#!/usr/bin/env bash
#
# GitOps Metal Foundry - Bootstrap Script
#
# Run from your local machine (Mac/Linux). This script will:
#   1. Install required tools (oci-cli, gh, jq) if missing
#   2. Create OCI API key for GitHub Actions
#   3. Set GitHub secrets via `gh` CLI (no manual steps!)
#   4. Create terraform.tfvars and push to repo
#
# Usage:
#   ./bootstrap.sh
#
# Or run directly:
#   curl -sSL https://raw.githubusercontent.com/vietcgi/gitops-metal-foundry/main/bootstrap.sh | bash
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

# Detect OS
OS="$(uname -s)"

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
# Step 1: Install Dependencies
#=============================================================================

install_homebrew() {
    if ! command -v brew &> /dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add to PATH for this session
        if [[ "$OS" == "Darwin" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
        else
            eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        fi
    fi
}

install_dependencies() {
    log_info "Checking dependencies..."

    local missing=()
    for cmd in jq git openssl curl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    # Check for OCI CLI
    if ! command -v oci &> /dev/null; then
        missing+=("oci-cli")
    fi

    # Check for GitHub CLI
    if ! command -v gh &> /dev/null; then
        missing+=("gh")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_success "All dependencies installed"
        return
    fi

    log_info "Missing: ${missing[*]}"
    log_info "Installing dependencies..."

    case "$OS" in
        Darwin)
            # macOS - use Homebrew
            install_homebrew

            for pkg in "${missing[@]}"; do
                case "$pkg" in
                    oci-cli)
                        log_info "Installing OCI CLI..."
                        brew install oci-cli
                        ;;
                    gh)
                        log_info "Installing GitHub CLI..."
                        brew install gh
                        ;;
                    jq|git|openssl|curl)
                        brew install "$pkg"
                        ;;
                esac
            done
            ;;
        Linux)
            # Linux - detect distro
            if command -v apt-get &> /dev/null; then
                # Debian/Ubuntu
                sudo apt-get update -qq

                for pkg in "${missing[@]}"; do
                    case "$pkg" in
                        oci-cli)
                            log_info "Installing OCI CLI..."
                            bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
                            export PATH="$HOME/bin:$PATH"
                            ;;
                        gh)
                            log_info "Installing GitHub CLI..."
                            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
                            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
                            sudo apt-get update -qq
                            sudo apt-get install -y gh
                            ;;
                        jq|git|curl)
                            sudo apt-get install -y "$pkg"
                            ;;
                        openssl)
                            sudo apt-get install -y openssl
                            ;;
                    esac
                done
            elif command -v dnf &> /dev/null; then
                # Fedora/RHEL
                for pkg in "${missing[@]}"; do
                    case "$pkg" in
                        oci-cli)
                            log_info "Installing OCI CLI..."
                            bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
                            export PATH="$HOME/bin:$PATH"
                            ;;
                        gh)
                            log_info "Installing GitHub CLI..."
                            sudo dnf install -y 'dnf-command(config-manager)'
                            sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
                            sudo dnf install -y gh
                            ;;
                        jq|git|curl|openssl)
                            sudo dnf install -y "$pkg"
                            ;;
                    esac
                done
            elif command -v yum &> /dev/null; then
                # CentOS/older RHEL
                for pkg in "${missing[@]}"; do
                    case "$pkg" in
                        oci-cli)
                            log_info "Installing OCI CLI..."
                            bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
                            export PATH="$HOME/bin:$PATH"
                            ;;
                        gh)
                            log_info "Installing GitHub CLI..."
                            sudo yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
                            sudo yum install -y gh
                            ;;
                        jq|git|curl|openssl)
                            sudo yum install -y "$pkg"
                            ;;
                    esac
                done
            else
                log_error "Unsupported Linux distribution"
                log_error "Please install manually: ${missing[*]}"
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    log_success "Dependencies installed"
}

#=============================================================================
# Step 2: Validate Authentication
#=============================================================================

validate_auth() {
    OCI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"

    # Check if already authenticated (just check config file exists)
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        log_success "OCI CLI configured"
    else
        log_warn "OCI CLI not configured"
        echo ""
        echo -e "${BOLD}Opening browser for OCI login...${NC}"
        echo ""

        # Get region from user
        read -r -p "Enter your OCI region (e.g., us-sanjose-1, us-ashburn-1): " OCI_REGION_INPUT

        if [[ -z "$OCI_REGION_INPUT" ]]; then
            log_error "Region is required"
            exit 1
        fi

        # Browser-based authentication (much easier than manual setup)
        log_info "Opening browser for authentication..."
        oci session authenticate --region "$OCI_REGION_INPUT"

        if [[ ! -f "$OCI_CONFIG_FILE" ]]; then
            log_error "OCI authentication failed"
            exit 1
        fi
        log_success "OCI CLI configured"
    fi

    # Check GitHub CLI authentication
    log_info "Checking GitHub CLI authentication..."

    if ! gh auth status &> /dev/null; then
        log_warn "GitHub CLI not authenticated"
        echo ""
        log_info "Opening browser for GitHub login..."
        gh auth login --web
    fi

    if ! gh auth status &> /dev/null; then
        log_error "GitHub CLI authentication failed"
        exit 1
    fi
    log_success "GitHub CLI authenticated"
}

#=============================================================================
# Step 3: Get OCI Configuration from CLI
#=============================================================================

get_oci_config() {
    log_info "Reading OCI configuration..."

    OCI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
    OCI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"

    if [[ ! -f "$OCI_CONFIG_FILE" ]]; then
        log_error "No OCI configuration found"
        exit 1
    fi

    # Helper to parse config file
    parse_oci_config() {
        local key=$1
        awk -v profile="[$OCI_PROFILE]" -v key="$key" '
            $0 == profile { found=1; next }
            /^\[/ { found=0 }
            found && $0 ~ "^"key"[[:space:]]*=" {
                sub(/^[^=]*=[[:space:]]*/, "")
                print
                exit
            }
        ' "$OCI_CONFIG_FILE"
    }

    # Read config values
    OCI_TENANCY=$(parse_oci_config "tenancy")
    OCI_REGION=$(parse_oci_config "region")
    OCI_USER=$(parse_oci_config "user")
    SECURITY_TOKEN_FILE=$(parse_oci_config "security_token_file")

    # Determine auth type
    if [[ -n "$SECURITY_TOKEN_FILE" ]]; then
        log_info "Using session token authentication"
        USE_SESSION_TOKEN=true
    else
        log_info "Using API key authentication"
        USE_SESSION_TOKEN=false
        OCI_KEY_FILE=$(parse_oci_config "key_file")
        OCI_KEY_FILE="${OCI_KEY_FILE/#\~/$HOME}"
    fi

    if [[ -z "$OCI_TENANCY" || -z "$OCI_REGION" ]]; then
        log_error "Could not read OCI config (tenancy/region missing)"
        exit 1
    fi

    log_success "Tenancy: ${OCI_TENANCY:0:40}..."
    log_success "Region: $OCI_REGION"
}

#=============================================================================
# Step 4: Get GitHub Repository
#=============================================================================

get_github_repo() {
    echo ""
    log_info "GitHub Repository Configuration"

    # Try to detect from current directory
    if git remote get-url origin &> /dev/null; then
        DETECTED_REPO=$(git remote get-url origin | sed 's|.*github.com[:/]||' | sed 's|\.git$||')
        log_info "Detected repo: $DETECTED_REPO"
        read -r -p "Use this repo? (Y/n): " use_detected
        if [[ ! "$use_detected" =~ ^[Nn]$ ]]; then
            GITHUB_REPO_FULL="$DETECTED_REPO"
        fi
    fi

    if [[ -z "${GITHUB_REPO_FULL:-}" ]]; then
        read -r -p "Enter GitHub repo (owner/repo): " GITHUB_REPO_FULL
    fi

    # Parse owner/repo
    GITHUB_REPO_FULL=$(echo "$GITHUB_REPO_FULL" | sed 's|https://github.com/||' | sed 's|\.git$||' | sed 's|/$||')
    GITHUB_OWNER=$(echo "$GITHUB_REPO_FULL" | cut -d'/' -f1)
    GITHUB_REPO=$(echo "$GITHUB_REPO_FULL" | cut -d'/' -f2)

    if [[ -z "$GITHUB_OWNER" || -z "$GITHUB_REPO" ]]; then
        log_error "Invalid repo format. Use: owner/repo"
        exit 1
    fi

    # Verify repo exists and we have access
    if ! gh repo view "$GITHUB_OWNER/$GITHUB_REPO" &> /dev/null; then
        log_error "Cannot access repo: $GITHUB_OWNER/$GITHUB_REPO"
        exit 1
    fi

    log_success "GitHub repo: $GITHUB_OWNER/$GITHUB_REPO"
}

#=============================================================================
# Step 5: Create OCI API Key for GitHub Actions
#=============================================================================

create_api_key() {
    log_info "Setting up OCI API key for GitHub Actions..."

    API_KEY_DIR="$HOME/.oci/github-actions"
    API_KEY_FILE="$API_KEY_DIR/oci_api_key.pem"
    API_KEY_PUBLIC="$API_KEY_DIR/oci_api_key_public.pem"

    # Set auth flag based on session or API key
    AUTH_FLAG=""
    if [[ "${USE_SESSION_TOKEN:-false}" == "true" ]]; then
        AUTH_FLAG="--auth security_token"
    fi

    # Get user OCID
    log_info "Getting user OCID..."
    OCI_USER=$(oci iam user list $AUTH_FLAG --limit 1 --query 'data[0].id' --raw-output 2>/dev/null)

    if [[ -z "$OCI_USER" ]]; then
        log_error "Could not determine user OCID"
        exit 1
    fi
    log_success "User: ${OCI_USER:0:50}..."

    # Always generate fresh key to avoid mismatches
    log_info "Generating new API key for GitHub Actions..."
    mkdir -p "$API_KEY_DIR"
    chmod 700 "$API_KEY_DIR"

    # Generate RSA 2048-bit key (OCI requirement)
    openssl genrsa -out "$API_KEY_FILE" 2048 2>/dev/null
    chmod 600 "$API_KEY_FILE"

    # Extract public key in PEM format
    openssl rsa -pubout -in "$API_KEY_FILE" -out "$API_KEY_PUBLIC" 2>/dev/null

    # Calculate fingerprint (OCI format)
    OCI_FINGERPRINT=$(cat "$API_KEY_PUBLIC" | openssl md5 -c | awk '{print $2}')
    OCI_KEY_CONTENT=$(cat "$API_KEY_FILE")

    log_success "Generated API key: $OCI_FINGERPRINT"

    # Upload public key to OCI
    log_info "Uploading API key to OCI..."

    # Check if key with this fingerprint already exists
    EXISTING_KEY=$(oci iam user api-key list $AUTH_FLAG \
        --user-id "$OCI_USER" \
        --query "data[?fingerprint=='$OCI_FINGERPRINT'].fingerprint | [0]" \
        --raw-output 2>/dev/null || echo "")

    if [[ -n "$EXISTING_KEY" && "$EXISTING_KEY" != "null" ]]; then
        log_success "API key already in OCI"
    else
        if oci iam user api-key upload $AUTH_FLAG \
            --user-id "$OCI_USER" \
            --key-file "$API_KEY_PUBLIC" 2>&1; then
            log_success "Uploaded API key to OCI"
        else
            log_error "Failed to upload API key"
            echo ""
            echo "Manual fix: Go to OCI Console → Identity → Users → API Keys"
            echo "Upload this public key:"
            echo ""
            cat "$API_KEY_PUBLIC"
            echo ""
            read -r -p "Press Enter after adding the key in OCI Console..."
        fi
    fi
}

#=============================================================================
# Step 6: Set GitHub Secrets
#=============================================================================

set_github_secrets() {
    log_info "Setting GitHub secrets..."

    # All secrets for Terraform OCI provider
    gh secret set OCI_CLI_USER -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_USER"
    gh secret set OCI_CLI_TENANCY -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_TENANCY"
    gh secret set OCI_CLI_FINGERPRINT -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_FINGERPRINT"
    gh secret set OCI_CLI_REGION -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_REGION"
    echo "$OCI_KEY_CONTENT" | gh secret set OCI_CLI_KEY_CONTENT -R "$GITHUB_OWNER/$GITHUB_REPO"

    # Terraform variables
    gh secret set TF_VAR_TENANCY_OCID -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_TENANCY"
    gh secret set TF_VAR_USER_OCID -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_USER"
    gh secret set TF_VAR_FINGERPRINT -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_FINGERPRINT"
    gh secret set TF_VAR_REGION -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_REGION"
    gh secret set TF_VAR_COMPARTMENT_OCID -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$OCI_COMPARTMENT"
    gh secret set TF_VAR_SSH_PUBLIC_KEY -R "$GITHUB_OWNER/$GITHUB_REPO" -b "$SSH_PUBLIC_KEY"
    echo "$OCI_KEY_CONTENT" | gh secret set TF_VAR_PRIVATE_KEY -R "$GITHUB_OWNER/$GITHUB_REPO"

    log_success "All secrets configured!"
}

#=============================================================================
# Step 7: Create Compartment
#=============================================================================

create_compartment() {
    log_info "Setting up OCI compartment..."

    PROJECT_NAME="${PROJECT_NAME:-metal-foundry}"

    # Set auth flag based on session or API key
    AUTH_FLAG=""
    if [[ "${USE_SESSION_TOKEN:-false}" == "true" ]]; then
        AUTH_FLAG="--auth security_token"
    fi

    EXISTING=$(oci iam compartment list $AUTH_FLAG \
        --compartment-id "$OCI_TENANCY" \
        --query "data[?name=='${PROJECT_NAME}' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
        --raw-output 2>/dev/null || echo "")

    if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
        log_info "Using existing compartment: $PROJECT_NAME"
        OCI_COMPARTMENT="$EXISTING"
    else
        log_info "Creating compartment: $PROJECT_NAME"
        OCI_COMPARTMENT=$(oci iam compartment create $AUTH_FLAG \
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
}

#=============================================================================
# Step 8: Get SSH Key
#=============================================================================

get_ssh_key() {
    log_info "SSH public key for VM access"
    echo ""

    SSH_PUBLIC_KEY=""

    # Check for existing keys
    for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        if [[ -f "$key_file" ]]; then
            log_info "Found: $key_file"
            read -r -p "Use this key? (Y/n): " use_existing
            if [[ ! "$use_existing" =~ ^[Nn]$ ]]; then
                SSH_PUBLIC_KEY=$(cat "$key_file")
                log_success "Using $key_file"
                return
            fi
        fi
    done

    echo "Paste your SSH public key (or press Enter to skip):"
    read -r SSH_PUBLIC_KEY

    if [[ -z "$SSH_PUBLIC_KEY" ]]; then
        log_warn "No SSH key - you won't be able to SSH into VMs"
    fi
}

#=============================================================================
# Step 9: Summary
#=============================================================================

print_summary() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  Bootstrap Complete!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}GitHub Secrets configured:${NC}"
    echo "  - OCI_CLI_USER, OCI_CLI_TENANCY, OCI_CLI_FINGERPRINT"
    echo "  - OCI_CLI_KEY_CONTENT, OCI_CLI_REGION"
    echo "  - TF_VAR_tenancy_ocid, TF_VAR_compartment_ocid"
    echo "  - TF_VAR_region, TF_VAR_ssh_public_key"
    echo ""
    echo -e "${BOLD}Next:${NC} Trigger GitHub Actions workflow"
    echo "  https://github.com/$GITHUB_OWNER/$GITHUB_REPO/actions"
    echo ""
    echo -e "${GREEN}  Cost: \$0.00/month (Oracle Always Free Tier)${NC}"
    echo ""
}

#=============================================================================
# Main
#=============================================================================

main() {
    banner
    install_dependencies
    validate_auth
    get_oci_config
    get_github_repo
    create_compartment
    get_ssh_key
    create_api_key
    set_github_secrets
    print_summary
}

# Handle errors
trap 'log_error "Bootstrap failed at line $LINENO"' ERR

main "$@"
