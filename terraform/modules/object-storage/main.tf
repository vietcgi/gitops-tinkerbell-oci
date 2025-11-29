#=============================================================================
# Object Storage Module
#
# Creates object storage bucket for Terraform state and backups.
# Uses Always Free tier (10GB included).
#=============================================================================

# Get object storage namespace
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_id
}

#-----------------------------------------------------------------------------
# State/Backup Bucket
#-----------------------------------------------------------------------------

resource "oci_objectstorage_bucket" "state" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${var.project_name}-state"
  access_type    = "NoPublicAccess"

  # Enable versioning for state safety
  versioning = "Enabled"

  # Auto-tiering to optimize storage (free tier compatible)
  auto_tiering = "InfrequentAccess"

  freeform_tags = var.tags

  # Prevent accidental deletion of state/backup bucket
  lifecycle {
    prevent_destroy = true
  }
}

#-----------------------------------------------------------------------------
# Lifecycle Policy - Clean up old versions (optional)
# Requires IAM policy: Allow service objectstorage-<region> to manage object-family in compartment id <compartment>
#-----------------------------------------------------------------------------

resource "oci_objectstorage_object_lifecycle_policy" "state" {
  count = var.create_lifecycle_policy ? 1 : 0

  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.state.name

  rules {
    name        = "delete-old-versions"
    action      = "DELETE"
    is_enabled  = true
    time_amount = 30
    time_unit   = "DAYS"

    target = "previous-object-versions"
  }

  rules {
    name        = "delete-old-backups"
    action      = "DELETE"
    is_enabled  = true
    time_amount = 90
    time_unit   = "DAYS"

    target = "objects"

    object_name_filter {
      inclusion_prefixes = ["backups/"]
    }
  }
}

#-----------------------------------------------------------------------------
# Pre-authenticated Request for Backup Access (Optional)
#-----------------------------------------------------------------------------

# This creates a URL that can be used for backups without OCI credentials
# Useful for etcd backup jobs running in K8s

resource "oci_objectstorage_preauthrequest" "backup" {
  count = var.create_backup_par ? 1 : 0

  namespace    = data.oci_objectstorage_namespace.ns.namespace
  bucket       = oci_objectstorage_bucket.state.name
  name         = "${var.project_name}-backup-access"
  access_type  = "AnyObjectReadWrite"
  time_expires = timeadd(timestamp(), "8760h") # 1 year

  bucket_listing_action = "ListObjects"
}
