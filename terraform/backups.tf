# Object Storage bucket for nightly database backups (logical pg_dumpall of
# supabase-db, uploaded by the host cron in ansible/muffin_stack.yml via the
# S3-compatible endpoint using the same Customer Secret Keys as the tfstate
# backend). Retention is enforced here by a lifecycle policy, so the backup
# script never has to prune. Reuses `data.oci_objectstorage_namespace.ns` from
# state-backend.tf.
resource "oci_objectstorage_bucket" "db_backups" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${var.name_prefix}-db-backups"
}

# Auto-delete backup objects older than 30 days.
resource "oci_objectstorage_object_lifecycle_policy" "db_backups" {
  bucket    = oci_objectstorage_bucket.db_backups.name
  namespace = data.oci_objectstorage_namespace.ns.namespace

  rules {
    name        = "expire-old-db-backups"
    action      = "DELETE"
    time_amount = 30
    time_unit   = "DAYS"
    is_enabled  = true
    target      = "objects"
    object_name_filter {
      inclusion_prefixes = ["supabase-db/"]
    }
  }
}

output "db_backups_bucket" { value = oci_objectstorage_bucket.db_backups.name }
