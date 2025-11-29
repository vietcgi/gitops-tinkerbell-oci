terraform {
  required_version = ">= 1.5.0" # Compatible with OCI Cloud Shell

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 7.27.0" # Nov 2025
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.6" # Nov 2025
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.2" # Nov 2025
    }
  }

  # State stored in OCI Object Storage (S3-compatible)
  backend "s3" {
    bucket                      = "metal-foundry-state"
    key                         = "terraform.tfstate"
    region                      = "us-sanjose-1"
    endpoints = {
      s3 = "https://axs1yzmj7jbw.compat.objectstorage.us-sanjose-1.oraclecloud.com"
    }
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

provider "oci" {
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key      = var.private_key
}
