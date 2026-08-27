variable "tenancy_ocid" {
  description = "OCID of your Tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the User"
  type        = string
}

variable "private_key_path" {
  description = "Path to the private key"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the public key"
  type        = string
}

variable "region" {
  description = "OCI Region"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the Compartment"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
}

variable "name_prefix" {
  description = "Name prefix"
  type        = string
}

variable "operating_system" {
  description = "Operating system"
  type        = string
}

variable "availability_domain" {
  description = "Availability domain"
  type        = number
}

variable "shape" {
  description = "Shape"
  type        = string
}

variable "node_count" {
  description = "Node count"
  type        = number
}

variable "ocpus" {
  description = "CPUs"
  type        = number
}

variable "memory_in_gbs" {
  description = "RAM"
  type        = number
}

variable "public_tcp_ports" {
  description = "Public TCP ports"
  type        = set(number)
}

variable "public_udp_ports" {
  description = "Public UDP ports"
  type        = set(number)
}

# === Cloudflare (optional — see cloudflare.tf). Empty cloudflare_domain disables all CF resources. ===
variable "cloudflare_domain" {
  description = "Apex domain managed in Cloudflare (e.g. rafiki.guru). Empty string disables Cloudflare."
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (Zone:DNS:Edit + Zone:Read + Account Access: Apps/Policies/Service Tokens: Edit)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for cloudflare_domain (zone overview page → API section)."
  type        = string
  default     = ""
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID (zone overview page → API section)."
  type        = string
  default     = ""
}

variable "cloudflare_app_subdomain" {
  description = "Subdomain for the Muffin app (Expo/React Native web client)."
  type        = string
  default     = "muffin"
}

variable "cloudflare_chat_subdomain" {
  description = "Subdomain for the legacy agent-chat-ui."
  type        = string
  default     = "muffin-chat"
}

variable "cloudflare_api_subdomain" {
  description = "Subdomain for the LangGraph API."
  type        = string
  default     = "api"
}

variable "cloudflare_supabase_subdomain" {
  description = "Subdomain for the Supabase API gateway (public — no Access app)."
  type        = string
  default     = "supabase"
}

variable "cloudflare_studio_subdomain" {
  description = "Subdomain for Supabase Studio (admin; behind an Access app)."
  type        = string
  default     = "supabase-studio"
}

variable "cloudflare_grafana_subdomain" {
  description = "Subdomain for Grafana (ops dashboards; behind an Access app)."
  type        = string
  # NOT the bare `grafana`/`portainer`: measured 2026-08-27, `portainer.rafiki.guru` ALREADY EXISTS
  # on this zone pointing at a different host (130.162.186.229) and is unproxied with no Access app.
  # Terraform would take the record over and silently move somebody's existing service.
  default = "muffin-grafana"
}

variable "cloudflare_portainer_subdomain" {
  description = "Subdomain for Portainer (container ops; behind an Access app). See the note on the Grafana subdomain — a bare `portainer` record may already exist on the zone."
  type        = string
  default     = "muffin-portainer"
}

variable "cloudflare_access_emails" {
  description = "Emails allowed through Cloudflare Access (Zero Trust)."
  type        = list(string)
  default     = []
}

variable "cloudflare_create_service_token" {
  description = "Create a Cloudflare Access service token (needs 'Access: Service Tokens: Edit' on the API token)."
  type        = bool
  default     = false
}

variable "ssh_private_key_path" {
  description = "Path to the SSH PRIVATE key (pair of ssh_public_key_path) used by Ansible to reach the node."
  type        = string
}

variable "data_volume_size_in_gbs" {
  description = "Size of the persistent data volume holding Docker's data-root. Can only GROW in place — shrinking forces replacement, so size generously."
  type        = number
  default     = 100
}

variable "data_volume_vpus_per_gb" {
  description = "Block volume performance tier. 10 = Balanced (matches the boot volume); 0 = Lower Cost, a real regression for Postgres."
  type        = number
  default     = 10
}

variable "data_volume_device_hint" {
  description = "Device the paravirtualized data volume is expected to appear as. The node has only sda, so a single attachment is deterministic."
  type        = string
  default     = "/dev/sdb"
}
