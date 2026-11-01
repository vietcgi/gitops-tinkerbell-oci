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
    subnet_id = var.subnet_id
    # No ephemeral public IP — a RESERVED one is attached below so the address
    # survives stop/start (Omni bakes it into every colo node's WireGuard config).
    assign_public_ip = false
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
# Reserved (static) Public IP  —  $0 on Always Free
#
# Omni (hosted on this node) advertises this IP as its SideroLink/WireGuard
# endpoint, which every colo Talos node phones home to. An ephemeral IP can be
# released on stop/start and would silently break the whole fleet, so we pin a
# reserved one. The VNIC above is created WITHOUT an ephemeral IP; the reserved
# IP binds to its primary private IP.
#
# !! SAFE-APPLY (this node is LIVE — k3s + Tailscale + apps) !!
# Flipping assign_public_ip true->false can make `terraform apply` want to
# REPLACE the instance (VNIC details are set at launch). DO NOT apply a plan that
# shows the instance being destroyed/recreated. Safe procedure:
#   1) Reserve + attach the IP out-of-band so the node is never recreated:
#        VNIC=$(oci compute instance list-vnics --instance-id <instance-ocid> \
#                 --query 'data[0]."id"' --raw-output)
#        PRIV=$(oci network private-ip list --vnic-id "$VNIC" \
#                 --query 'data[?"is-primary"]|[0].id' --raw-output)
#        # delete the current ephemeral public IP on that private IP (brief IP change;
#        # mgmt access is safe via Tailscale), then:
#        oci network public-ip create --compartment-id <compartment> \
#          --lifetime RESERVED --private-ip-id "$PRIV" \
#          --display-name metal-foundry-control-plane-reserved-ip
#   2) Import it so state matches and future plans are clean:
#        terraform import 'module.control_plane.oci_core_public_ip.control_plane' <reserved-ip-ocid>
#   3) Confirm `terraform plan` no longer wants to replace the instance.
#-----------------------------------------------------------------------------

# Primary VNIC of the control-plane instance
data "oci_core_vnic_attachments" "control_plane" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.control_plane.id
}

# Private IPs on that VNIC — [0] is the primary on a single-IP node
data "oci_core_private_ips" "control_plane" {
  vnic_id = data.oci_core_vnic_attachments.control_plane.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "control_plane" {
  compartment_id = var.compartment_id
  lifetime       = "RESERVED"
  display_name   = "${var.project_name}-control-plane-reserved-ip"
  private_ip_id  = data.oci_core_private_ips.control_plane.private_ips[0].id
  freeform_tags  = var.tags
}
