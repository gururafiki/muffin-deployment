# Terraform → Ansible chaining: one `terraform apply` provisions the VM + Cloudflare AND configures
# the Swarm + deploys the stack. Inventory is read dynamically from this Terraform state by Ansible's
# cloud.terraform collection (no static inventory file / generate_inventory.sh).

provider "ansible" {}

# One inventory host per instance, with groups + connection vars (consumed by the
# cloud.terraform.terraform_provider inventory plugin in ../ansible/inventory.yml).
resource "ansible_host" "node" {
  count  = var.node_count
  name   = oci_core_instance.node[count.index].public_ip
  groups = [count.index == 0 ? "manager" : "workers"]
  variables = {
    ansible_user                 = "ubuntu"
    ansible_ssh_private_key_file = pathexpand(var.ssh_private_key_path)
    private_ip                   = oci_core_instance.node[count.index].private_ip
  }
}

# Run the playbook inside `apply`, after the hosts (and DNS) exist. Re-runs (idempotent) when an
# instance is replaced. A mid-run Ansible failure taints this resource; re-`apply` re-runs it.
resource "terraform_data" "ansible" {
  triggers_replace = [for n in oci_core_instance.node : n.id]
  depends_on       = [ansible_host.node, cloudflare_dns_record.muffin]

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = "ansible-galaxy collection install cloud.terraform:4.0.0 community.general:10.7.3 >/dev/null && ansible-playbook -i inventory.yml muffin_stack.yml"
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
  }
}
