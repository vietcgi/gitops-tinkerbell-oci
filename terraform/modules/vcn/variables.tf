variable "compartment_id" {
  description = "Compartment OCID"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "vcn_cidr" {
  description = "VCN CIDR block"
  type        = string
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR"
  type        = string
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "ssh_source_cidr" {
  description = "CIDR block allowed for SSH access (default: anywhere - CHANGE for production)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "admin_source_cidr" {
  description = "CIDR block allowed for K8s API access (default: anywhere - CHANGE for production)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "admin_source_cidrs" {
  description = "Admin allow-list for the control/admin planes: k8s API 6443, Omni UI/API 8443, Omni k8s-proxy 8100, Dex 5556. One SL/NSG rule is generated per CIDR. Set the real value in a gitignored *.auto.tfvars (never commit IPs to this public repo)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
