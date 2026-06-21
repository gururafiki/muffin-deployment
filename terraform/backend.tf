# Remote Terraform state on OCI Object Storage (S3-compatible). Auth is via an OCI Customer Secret
# Key supplied as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (env), separate from the OCI API key.
terraform {
  backend "s3" {
    bucket = "muffin-tfstate"
    key    = "muffin-deployment/terraform.tfstate"
    region = "uk-london-1"
    endpoints = {
      s3 = "https://lrjqtgyopxbk.compat.objectstorage.uk-london-1.oraclecloud.com"
    }
    use_path_style              = true # OCI requires path-style addressing
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true # OCI S3-compat rejects AWS's default integrity checksums
  }
}
