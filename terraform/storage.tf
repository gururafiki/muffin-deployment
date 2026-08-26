# The persistent data volume — the fix for the hazard README.md documents.
#
# WHY THIS EXISTS. Every Docker named volume lived on the instance's BOOT volume, which is
# destroyed with the instance. On 2026-07-20 an image rotation made a routine `terraform apply`
# replace the node and wipe every database. `main.tf`'s `ignore_changes` stops that particular
# trigger; it does not make the data durable. A block volume survives instance replacement. That
# is the entire point of this file.
#
# Docker's whole `data-root` moves here (see ansible/roles/block_storage), so images, every named
# volume, container layers and swarm state all land on it together. A replaced instance reattaches
# this volume and finds everything already present — nothing to restore.

resource "oci_core_volume" "data" {
  compartment_id = var.compartment_ocid

  # MUST be the same expression as the instance's (main.tf). A block volume attaches only within
  # its own availability domain — a drift here creates the volume successfully and then fails at
  # ATTACH time, leaving an orphan that still counts against the Always Free allowance.
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain].name

  display_name = "${var.name_prefix}-data"
  size_in_gbs  = var.data_volume_size_in_gbs

  # 10 = Balanced, the tier the boot volume already runs at, so moving PGDATA here is a lateral
  # move rather than a regression. 0 (Lower Cost) caps IOPS in a way Postgres random I/O feels.
  vpus_per_gb = var.data_volume_vpus_per_gb

  # The one resource in this repo that warrants this. Everything irreplaceable ends up here, and
  # `terraform apply -auto-approve` runs unattended on every image-repo dispatch. If the volume
  # ever needs to go, the escape hatch is `terraform state rm` plus a console delete — deliberate,
  # manual, and impossible to do by accident.
  lifecycle {
    prevent_destroy = true
  }
}

# PARAVIRTUALIZED, not iSCSI. iSCSI attachments require in-guest `iscsiadm` login commands to be
# re-established after every reboot, and this deployment has no cloud-init and no `user_data` —
# Ansible only runs on deploy, so there is nowhere to express that. A paravirtualized volume simply
# appears as a block device and survives reboots with no in-guest state at all.
#
# NOTE: no `prevent_destroy` here, deliberately. If the instance is ever replaced the attachment
# MUST be replaceable — guarding it would deadlock the exact recovery this volume exists to enable.
# The volume itself is what must survive, and it does.
resource "oci_core_volume_attachment" "data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.node[0].id
  volume_id       = oci_core_volume.data.id
}
