variable "compartment_id" {
  description = "Compartment OCID"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "create_backup_par" {
  description = "Create pre-authenticated request for backups"
  type        = bool
  default     = false
}

variable "create_lifecycle_policy" {
  description = "Create lifecycle policy (requires service-level IAM policy)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
