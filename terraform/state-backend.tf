# OCI Object Storage bucket holding the remote Terraform state (S3-compatible backend).
# Created with the existing OCI API-key auth; the s3 backend block (added once the bucket exists)
# authenticates separately with an OCI Customer Secret Key via AWS_ACCESS_KEY_ID/SECRET.
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${var.name_prefix}-tfstate"
  versioning     = "Enabled" # keep state history for recovery
}

output "tfstate_bucket" { value = oci_objectstorage_bucket.tfstate.name }
output "tfstate_namespace" { value = data.oci_objectstorage_namespace.ns.namespace }
output "tfstate_s3_endpoint" {
  value = "https://${data.oci_objectstorage_namespace.ns.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}
