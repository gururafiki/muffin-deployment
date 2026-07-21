# Object Storage bucket for nightly database backups (logical pg_dumpall of
# supabase-db, uploaded by the host cron in ansible/muffin_stack.yml via the
# S3-compatible endpoint using the same Customer Secret Keys as the tfstate
# backend). Reuses `data.oci_objectstorage_namespace.ns` from state-backend.tf.
#
# Retention (30 days) is pruned by the backup script itself, NOT an OCI
# object-lifecycle policy: lifecycle policies require a tenancy IAM grant to the
# Object Storage service principal ("Allow service objectstorage-<region> to
# manage object-family ..."), which fails with 400-InsufficientServicePermissions
# without it and adds IAM-propagation flakiness. Script-side pruning keeps this
# self-contained.
resource "oci_objectstorage_bucket" "db_backups" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${var.name_prefix}-db-backups"
}

output "db_backups_bucket" { value = oci_objectstorage_bucket.db_backups.name }
