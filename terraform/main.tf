#=============================================================================
# GitOps Metal Foundry - Main Terraform Configuration
#
# This creates the Oracle Cloud infrastructure for the control plane.
# ALL resources use Always Free tier - $0/month guaranteed.
#=============================================================================

locals {
  # Common tags for all resources
  common_tags = {
    Project     = var.project_name
    Environment = "production"
    ManagedBy   = "terraform"
    CostCenter  = "free-tier"
  }

  # Determine if using AMD or ARM shape
  is_arm = var.control_plane_shape == "VM.Standard.A1.Flex"
}

# Note: ubuntu_image_id local is defined below after data sources

#=============================================================================
# Data Sources
#=============================================================================

# Get availability domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Get latest Ubuntu LTS image compatible with shape
# Ubuntu 24.04 may not be available in all regions for ARM - fallback to 22.04
data "oci_core_images" "ubuntu_24" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.control_plane_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_core_images" "ubuntu_22" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.control_plane_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  # Use Ubuntu 24.04 if available, otherwise fallback to 22.04
  ubuntu_image_id = length(data.oci_core_images.ubuntu_24.images) > 0 ? data.oci_core_images.ubuntu_24.images[0].id : data.oci_core_images.ubuntu_22.images[0].id
}

#=============================================================================
# Networking Module
#=============================================================================

module "vcn" {
  source = "./modules/vcn"

  compartment_id      = var.compartment_ocid
  project_name        = var.project_name
  vcn_cidr            = var.vcn_cidr
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  ssh_source_cidr     = var.ssh_source_cidr
  admin_source_cidr   = var.admin_source_cidr
  tags                = local.common_tags
}

#=============================================================================
# Compute Module - Control Plane
#=============================================================================

module "control_plane" {
  source = "./modules/compute"

  compartment_id = var.compartment_ocid
  # Use modulo to handle regions with fewer ADs than requested index
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[
    var.availability_domain_index % length(data.oci_identity_availability_domains.ads.availability_domains)
  ].name
  project_name = var.project_name
  subnet_id    = module.vcn.public_subnet_id
  nsg_ids      = [module.vcn.control_plane_nsg_id]

  # Instance configuration
  shape          = var.control_plane_shape
  ocpus          = local.is_arm ? var.control_plane_ocpus : null
  memory_gb      = local.is_arm ? var.control_plane_memory_gb : null
  image_id       = local.ubuntu_image_id
  ssh_public_key = var.ssh_public_key

  # Boot volume
  boot_volume_size_gb = var.boot_volume_size_gb

  # Cloud-init configuration
  tailscale_auth_key = var.tailscale_auth_key
  domain             = var.domain

  tags = local.common_tags
}

# Note: Object storage bucket (metal-foundry-state) is created outside Terraform
# because it's used for Terraform state storage (chicken-and-egg problem)

#=============================================================================
# IAM Module - Optional policies
#=============================================================================

module "iam" {
  source = "./modules/iam"

  tenancy_id     = var.tenancy_ocid
  compartment_id = var.compartment_ocid
  project_name   = var.project_name
  create_policy  = false # Not needed - using API key auth from GitHub Actions
  tags           = local.common_tags
}
