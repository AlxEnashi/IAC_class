#!/usr/bin/env bash
# Writes ansible/inventory/hosts.yml from the Terraform outputs.
# Usage: scripts/make-inventory.sh   (SSH_PRIVATE_KEY overrides the key path)
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
ip="$(terraform -chdir="$here/terraform" output -raw public_ip)"
key="${SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519}"

mkdir -p "$here/ansible/inventory"
cat > "$here/ansible/inventory/hosts.yml" <<YAML
all:
  hosts:
    demo:
      ansible_host: ${ip}
      ansible_user: ec2-user
      ansible_ssh_private_key_file: ${key}
YAML

echo "Wrote ansible/inventory/hosts.yml for ${ip}"
