#!/bin/bash
# Copy this directory to a machine inside the closed network and install OpenBao.
# On the target itself:  sudo ./install.sh
# From another host:     ./deploy.sh root@10.0.0.5

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -eq 0 ]]; then
  exec sudo "${ROOT}/install.sh"
fi

if [[ $# -ne 1 ]]; then
  echo "Использование: ./deploy.sh root@10.0.0.5" >&2
  exit 1
fi

target="$1"
remote="/opt/openbao-ansible"

ssh "$target" "mkdir -p '${remote}'"
tar -C "$ROOT" -cf - \
  --exclude .git \
  --exclude inventory/hosts.ini \
  --exclude files/tls.key \
  --exclude files/tls.crt \
  . | ssh "$target" "tar -xf - -C '${remote}'"
ssh -t "$target" "sudo '${remote}/install.sh'"
