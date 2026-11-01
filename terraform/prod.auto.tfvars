# Non-secret deployment constants (auto-loaded). Secret + user-specific values come from
# GitHub secrets/variables via the deploy workflow (TF_VAR_*), or terraform.tfvars locally.
availability_domain = 0
operating_system    = "Canonical Ubuntu"
name_prefix         = "muffin"
shape               = "VM.Standard.A1.Flex"
node_count          = 1
ocpus               = 4
memory_in_gbs       = 24
public_tcp_ports    = [80, 443]
public_udp_ports    = []

cloudflare_create_service_token = true

# Block storage: 95 GB boot + 105 GB data = 200 GB, the whole Always Free allowance.
#
# The allowance is REGIONAL and covers boot and block volumes together: OCI's own limit
# `total-free-storage-gb-regional` is 200, and before this change it read 195 used, 5 available
# (measured 2026-11-01). Anything past 200 is billed at about $0.0425 per GB-month for Balanced, and
# a volume can never shrink, so the next grow is a decision about money, not a default.
#
# Boot volume: the OS and containerd's image store, which Docker's data-root does NOT move. Grown
# from the image default of 46.6 GB on 2026-09-25, when `/` reached 89%. Grown IN PLACE; see the
# variable in variables.tf.
boot_volume_size_in_gbs = 95

# Persistent data volume (Docker data-root). See terraform/storage.tf. Grown 100 -> 105 on
# 2026-11-01 with the last free 5 GB, when /mnt/data reached 76% during the SEC filer backfill. Grown
# IN PLACE; the filesystem follows in ansible/roles/block_storage.
data_volume_size_in_gbs = 105
data_volume_vpus_per_gb = 10
