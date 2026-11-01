#=============================================================================
# Compute Module - Control Plane VM
#
# Creates the control plane VM using Always Free tier shapes only.
#=============================================================================

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
    cloudinit = {
      source = "hashicorp/cloudinit"
    }
  }
}

locals {
  is_arm = var.shape == "VM.Standard.A1.Flex"
}

#-----------------------------------------------------------------------------
# Cloud-Init Configuration
#-----------------------------------------------------------------------------

data "cloudinit_config" "control_plane" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloud-init.yaml", {
      hostname           = "${var.project_name}-control"
      tailscale_auth_key = var.tailscale_auth_key
      domain             = var.domain
    })
  }
}

#-----------------------------------------------------------------------------
# Control Plane Instance
#-----------------------------------------------------------------------------

resource "oci_core_instance" "control_plane" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  display_name        = "${var.project_name}-control-plane"

  shape = var.shape

  # Shape config only for flexible shapes (A1.Flex)
  dynamic "shape_config" {
    for_each = local.is_arm ? [1] : []
    content {
      ocpus         = var.ocpus
      memory_in_gbs = var.memory_gb
    }
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_id
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = true
    display_name     = "${var.project_name}-control-plane-vnic"
    hostname_label   = "control"
    nsg_ids          = var.nsg_ids
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = data.cloudinit_config.control_plane.rendered
  }

  # Delete boot volume on termination to avoid orphaned volumes
  preserve_boot_volume = false

  freeform_tags = var.tags

  # Lifecycle - prevent recreation on non-critical changes
  lifecycle {
    ignore_changes = [
      source_details[0].source_id, # Ignore image updates
      metadata,                    # Ignore cloud-init changes (run manually if needed)
    ]
  }
}

#-----------------------------------------------------------------------------
# Public IP  —  EPHEMERAL, left as-is (do NOT reserve/reassign)
#
# The node keeps its existing ephemeral public IP (currently 170.9.8.103). We do
# NOT reserve a new/secondary IP: none is available, and changing this address
# would disrupt the live client sites (it's the Cloudflare origin), the direct
# A-record for tinkerbell.qualityspace.com, and the colo firewall allow-list.
# Omni instead SHARES this one IP with the production Cilium Gateway:
#   - omni/auth .<domain> :443  -> existing Gateway HTTPS listener (HTTPRoute)
#   - :8090 / :8100 TCP + :50180/UDP -> Omni pod hostPorts
# See kubernetes/apps/omni/README.md. (Validated by Codex 2026-11-01.)
#-----------------------------------------------------------------------------
