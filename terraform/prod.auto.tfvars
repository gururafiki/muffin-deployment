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

# Persistent data volume (Docker data-root). See terraform/storage.tf.
# 46.6 GB boot + 100 GB data = 146.6 of the 200 GB Always Free block-storage allowance.
data_volume_size_in_gbs = 100
data_volume_vpus_per_gb = 10
