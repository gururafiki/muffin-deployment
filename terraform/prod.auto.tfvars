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

# Block storage: 95 GB boot + 100 GB data = 195 of the 200 GB Always Free allowance.
#
# Boot volume: the OS and containerd's image store, which Docker's data-root does NOT move. Grown
# from the image default of 46.6 GB on 2026-09-25, when `/` reached 89%. Grown IN PLACE; see the
# variable in variables.tf.
boot_volume_size_in_gbs = 95

# Persistent data volume (Docker data-root). See terraform/storage.tf.
data_volume_size_in_gbs = 100
data_volume_vpus_per_gb = 10
