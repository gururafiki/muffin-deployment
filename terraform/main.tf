terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "5.0.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "~> 1.3"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  private_key_path = var.private_key_path
  fingerprint      = var.fingerprint
  region           = var.region
}

# Used only when var.cloudflare_domain is set (see cloudflare.tf). The token is not
# read unless a Cloudflare resource is created, so the placeholder is harmless when disabled.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

resource "oci_core_vcn" "vcn" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "vcn"
  dns_label      = var.name_prefix
}

resource "oci_core_internet_gateway" "ig" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "internet-gateway"
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.ig.id
  }
}

resource "oci_core_security_list" "rules" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "rules"

  # Allow all internal VCN traffic
  ingress_security_rules {
    protocol = "all"
    source   = "10.0.0.0/16"
  }

  dynamic "ingress_security_rules" {
    for_each = var.public_tcp_ports
    content {
      protocol = "6"
      source   = "0.0.0.0/0"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.public_udp_ports
    content {
      protocol = "17"
      source   = "0.0.0.0/0"
      udp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }
}

# Get default security list for the VCN
data "oci_core_security_lists" "default" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  filter {
    name   = "display_name"
    values = ["Default Security List for ${oci_core_vcn.vcn.display_name}"]
  }
}

resource "oci_core_subnet" "subnet" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "subnet"
  dns_label      = var.name_prefix
  route_table_id = oci_core_route_table.rt.id

  # Combine default security list with custom rules
  security_list_ids = [
    data.oci_core_security_lists.default.security_lists[0].id,
    oci_core_security_list.rules.id
  ]
}

data "oci_core_images" "os" {
  compartment_id   = var.compartment_ocid
  operating_system = var.operating_system
  shape            = var.shape
}


resource "oci_core_instance" "node" {
  count               = var.node_count
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain].name
  shape               = var.shape
  display_name        = "${var.name_prefix}-node-${count.index}"
  # If the instance is ever destroyed/replaced, KEEP its boot volume instead of
  # deleting it — the single node stores every Docker named volume (Supabase +
  # LangGraph Postgres, storage, firecrawl) on the boot volume, so a preserved
  # volume is the last-resort way to recover that data. See lifecycle below for
  # why a replacement should never happen unintentionally in the first place.
  preserve_boot_volume = true
  timeouts {
    create = "60m"
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet.id
    assign_public_ip = true
    hostname_label   = "${var.name_prefix}-${count.index}"
  }

  source_details {
    source_id   = data.oci_core_images.os.images[0].id
    source_type = "image"
  }

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }

  # CRITICAL: `source_details.source_id` resolves to the *newest* matching OCI
  # platform image via the `oci_core_images` data source. Oracle publishes new
  # Canonical Ubuntu images periodically, so without this, a routine `terraform
  # apply` (i.e. any deploy) after an image rotation sees a changed `source_id`,
  # marks it `# forces replacement`, and DESTROYS + recreates the whole node —
  # wiping every local Docker volume (all databases). That is exactly what
  # happened on 2026-07-20. Pinning the image drift here keeps deploys as pure
  # in-place stack updates. A deliberate OS upgrade must be done consciously
  # (back up the DBs first, then remove this ignore or taint the instance).
  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }
}
