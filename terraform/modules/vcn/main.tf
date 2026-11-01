#=============================================================================
# VCN Module - Virtual Cloud Network
#
# Creates networking infrastructure for Metal Foundry.
# All resources are Always Free tier.
#=============================================================================

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

#-----------------------------------------------------------------------------
# VCN
#-----------------------------------------------------------------------------

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.project_name}-vcn"
  dns_label      = replace(var.project_name, "-", "")

  freeform_tags = var.tags
}

#-----------------------------------------------------------------------------
# Internet Gateway (for public subnet)
#-----------------------------------------------------------------------------

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-igw"
  enabled        = true

  freeform_tags = var.tags
}

#-----------------------------------------------------------------------------
# NAT Gateway (for private subnet outbound)
#-----------------------------------------------------------------------------

resource "oci_core_nat_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-nat"

  freeform_tags = var.tags
}

#-----------------------------------------------------------------------------
# Route Tables
#-----------------------------------------------------------------------------

# Public route table - routes to Internet Gateway
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  freeform_tags = var.tags
}

# Private route table - routes to NAT Gateway
resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.main.id
  }

  freeform_tags = var.tags
}

#-----------------------------------------------------------------------------
# Security Lists
#-----------------------------------------------------------------------------

# Public subnet security list
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-public-sl"

  # Egress - allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # Ingress - SSH (restrict to specific CIDR in production)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.ssh_source_cidr
    stateless   = false
    description = "SSH access - restrict source CIDR in production"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Ingress - HTTP
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "HTTP"

    tcp_options {
      min = 80
      max = 80
    }
  }

  # Ingress - HTTPS
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "HTTPS"

    tcp_options {
      min = 443
      max = 443
    }
  }

  # Ingress - Kubernetes API (restrict to specific CIDR in production)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.admin_source_cidr
    stateless   = false
    description = "Kubernetes API - restrict source CIDR in production"

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # Ingress - Tinkerbell HTTP boot
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Tinkerbell HTTP boot"

    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # Ingress - ICMP (ping)
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "ICMP ping"

    icmp_options {
      type = 8 # Echo request
    }
  }

  # Ingress - Tailscale/WireGuard UDP
  ingress_security_rules {
    protocol    = "17" # UDP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Tailscale/WireGuard"

    udp_options {
      min = 41641
      max = 41641
    }
  }

  # Ingress - Kubernetes NodePorts
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Kubernetes NodePort services"

    tcp_options {
      min = 30000
      max = 32767
    }
  }

  # Ingress - Tinkerbell gRPC (restricted to colo subnet)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "108.181.38.64/27"
    stateless   = false
    description = "Tinkerbell gRPC - locked to colo /27"

    tcp_options {
      min = 42113
      max = 42113
    }
  }

  # Ingress - Smee HTTP (restricted to colo subnet)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "108.181.38.64/27"
    stateless   = false
    description = "Smee HTTP for iPXE - locked to colo /27"

    tcp_options {
      min = 7171
      max = 7171
    }
  }

  # ---- Sidero Omni (apps/omni) — hostPort endpoints on this node ----
  # UI/API + Dex + k8s-proxy are admin-facing (TLS + OIDC-gated) -> open.
  # Ingress - Omni UI + API
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Omni UI/API (TLS)"

    tcp_options {
      min = 8443
      max = 8443
    }
  }

  # Ingress - Omni Kubernetes proxy (admin kubectl via Omni)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Omni k8s-proxy (TLS)"

    tcp_options {
      min = 8100
      max = 8100
    }
  }

  # Ingress - Dex OIDC (admin browser login)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Dex OIDC (TLS)"

    tcp_options {
      min = 5556
      max = 5556
    }
  }

  # Omni SideroLink/machine API + WireGuard are reached by the COLO nodes ->
  # locked to the colo /27 (broaden to 0.0.0.0/0 if colo egress differs).
  # Ingress - Omni SideroLink / machine API
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "108.181.38.64/27"
    stateless   = false
    description = "Omni SideroLink/machine API - locked to colo /27"

    tcp_options {
      min = 8090
      max = 8090
    }
  }

  # Ingress - Omni SideroLink WireGuard tunnel
  ingress_security_rules {
    protocol    = "17" # UDP
    source      = "108.181.38.64/27"
    stateless   = false
    description = "Omni SideroLink WireGuard - locked to colo /27"

    udp_options {
      min = 50180
      max = 50180
    }
  }

  freeform_tags = var.tags
}

# Private subnet security list
resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-private-sl"

  # Egress - allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # Ingress - allow all from VCN
  ingress_security_rules {
    protocol    = "all"
    source      = var.vcn_cidr
    stateless   = false
    description = "All traffic from VCN"
  }

  freeform_tags = var.tags
}

#-----------------------------------------------------------------------------
# Network Security Group - Control Plane
#-----------------------------------------------------------------------------

resource "oci_core_network_security_group" "control_plane" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-control-plane-nsg"

  freeform_tags = var.tags
}

# NSG rules for control plane
resource "oci_core_network_security_group_security_rule" "control_plane_egress" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "control_plane_ssh" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.ssh_source_cidr
  source_type               = "CIDR_BLOCK"
  description               = "SSH - restrict source CIDR in production"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_https" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "HTTPS - public access for ingress"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_k8s_api" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.admin_source_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Kubernetes API - restrict source CIDR in production"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_http" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "HTTP - for ingress and Let's Encrypt challenges"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_nodeports" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Kubernetes NodePort services"

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_icmp" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "ICMP ping for diagnostics"

  icmp_options {
    type = 8
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_tailscale" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Tailscale/WireGuard UDP"

  udp_options {
    destination_port_range {
      min = 41641
      max = 41641
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_tinkerbell_grpc" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "108.181.38.64/27"
  source_type               = "CIDR_BLOCK"
  description               = "Tinkerbell gRPC - locked to colo /27"

  tcp_options {
    destination_port_range {
      min = 42113
      max = 42113
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_smee_http" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "108.181.38.64/27"
  source_type               = "CIDR_BLOCK"
  description               = "Smee HTTP for iPXE - locked to colo /27"

  tcp_options {
    destination_port_range {
      min = 7171
      max = 7171
    }
  }
}

#-----------------------------------------------------------------------------
# Subnets
#-----------------------------------------------------------------------------

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${var.project_name}-public-subnet"
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]

  freeform_tags = var.tags
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.private_subnet_cidr
  display_name               = "${var.project_name}-private-subnet"
  dns_label                  = "private"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]

  freeform_tags = var.tags
}
