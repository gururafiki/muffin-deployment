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
