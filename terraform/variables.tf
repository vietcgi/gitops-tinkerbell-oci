#=============================================================================
# OCI Provider Authentication
#=============================================================================

variable "tenancy_ocid" {
  description = "OCI Tenancy OCID"
  type        = string
}

variable "user_ocid" {
  description = "OCI User OCID"
  type        = string
}

variable "fingerprint" {
  description = "OCI API Key fingerprint"
  type        = string
}

variable "private_key" {
  description = "OCI API private key content"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "OCI Region (e.g., us-ashburn-1)"
  type        = string
}

#=============================================================================
# Required Variables
#=============================================================================

variable "compartment_ocid" {
  description = "OCI Compartment OCID for resources"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

#=============================================================================
# Project Settings
#=============================================================================

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "metal-foundry"
}

#=============================================================================
# Free Tier Shapes - DO NOT MODIFY
# These are the ONLY shapes that are Always Free
#=============================================================================

variable "control_plane_shape" {
  description = "Control plane VM shape - MUST be Always Free"
  type        = string
  default     = "VM.Standard.A1.Flex" # ARM - 4 CPU + 24GB FREE

  validation {
    condition = contains([
      "VM.Standard.E2.1.Micro", # AMD, 1/8 OCPU, 1GB RAM - Always Free
      "VM.Standard.A1.Flex"     # ARM, up to 4 OCPU, 24GB RAM - Always Free
    ], var.control_plane_shape)
    error_message = "Only Always Free shapes are allowed: VM.Standard.E2.1.Micro or VM.Standard.A1.Flex"
  }
}

variable "control_plane_ocpus" {
  description = "OCPUs for A1.Flex shape (ignored for E2.1.Micro)"
  type        = number
  default     = 4 # Max free tier

  validation {
    condition     = var.control_plane_ocpus >= 1 && var.control_plane_ocpus <= 4
    error_message = "A1.Flex free tier allows 1-4 OCPUs total across all VMs"
  }
}

variable "control_plane_memory_gb" {
  description = "Memory in GB for A1.Flex shape (ignored for E2.1.Micro)"
  type        = number
  default     = 24 # Max free tier

  validation {
    condition     = var.control_plane_memory_gb >= 1 && var.control_plane_memory_gb <= 24
    error_message = "A1.Flex free tier allows 1-24GB total across all VMs"
  }
}

variable "boot_volume_size_gb" {
  description = "Boot volume size in GB (free tier: 200GB total)"
  type        = number
  default     = 200 # Use full free tier allowance for single instance

  validation {
    condition     = var.boot_volume_size_gb >= 47 && var.boot_volume_size_gb <= 200
    error_message = "Free tier allows up to 200GB total block storage"
  }
}

variable "availability_domain_index" {
  description = "Index of availability domain to use (0, 1, or 2). Try different values if capacity is unavailable."
  type        = number
  default     = 0

  validation {
    condition     = var.availability_domain_index >= 0 && var.availability_domain_index <= 2
    error_message = "Availability domain index must be 0, 1, or 2"
  }
}

#=============================================================================
# Optional Settings
#=============================================================================

variable "domain" {
  description = "Domain for TLS certificates (optional)"
  type        = string
  default     = ""
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for VPN mesh (optional)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_owner" {
  description = "GitHub owner/org for GitOps (optional)"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repo name for GitOps (optional)"
  type        = string
  default     = ""
}

#=============================================================================
# Network Settings
#=============================================================================

variable "vcn_cidr" {
  description = "VCN CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR"
  type        = string
  default     = "10.0.2.0/24"
}

variable "ssh_source_cidr" {
  description = "CIDR allowed for SSH access. Default allows anywhere - restrict in production!"
  type        = string
  default     = "0.0.0.0/0"
}

variable "admin_source_cidr" {
  description = "CIDR allowed for K8s API access. Default allows anywhere - restrict in production!"
  type        = string
  default     = "0.0.0.0/0"
}
