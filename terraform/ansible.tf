# Terraform → Ansible chaining, the native way: the ansible/ansible provider's `ansible_playbook`
# resource runs the playbook during `terraform apply` (no terraform_data + local-exec, no static
# inventory / generate_inventory.sh). `replayable = true` re-runs the idempotent playbook on every
# apply, so a deploy — including rolling a new `:latest` image via `docker stack deploy
# --resolve-image always` — is just `terraform apply` (no `-replace` needed).
#
# Single-node: the one instance is the Swarm manager. For a multi-node future, switch to
# `ansible_host`/`ansible_group` + the cloud.terraform dynamic inventory and run the play per group.

provider "ansible" {}

resource "ansible_playbook" "muffin" {
  name       = oci_core_instance.node[0].public_ip
  playbook   = abspath("${path.module}/../ansible/muffin_stack.yml")
  groups     = ["manager"]
  replayable = true

  extra_vars = {
    ansible_user                 = "ubuntu"
    ansible_ssh_private_key_file = pathexpand(var.ssh_private_key_path)
    # disable host-key checking per-connection (no reliance on ansible.cfg discovery / env)
    # ServerAliveInterval keeps a CI-driven session up through a long task. Without it an SSH
    # drop mid-play is exactly how a storage change ends up half-applied.
    ansible_ssh_common_args = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=20"
    private_ip              = oci_core_instance.node[0].private_ip
    # The persistent data volume. `extra_vars` is map(string) — an unquoted number or bool here is
    # a plan-time type error, so keep every value a string.
    data_mount_point        = "/mnt/data"
    data_volume_device_hint = var.data_volume_device_hint
  }

  # The volume attachment is a hard prerequisite: without it the playbook can run before the
  # device exists and the block_storage role fails on a node that is otherwise fine.
  depends_on = [
    oci_core_instance.node,
    cloudflare_dns_record.muffin,
    oci_objectstorage_bucket.db_backups,
    oci_core_volume_attachment.data,
  ]
}
