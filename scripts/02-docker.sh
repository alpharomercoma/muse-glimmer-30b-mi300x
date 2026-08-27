#!/usr/bin/env bash
# Step 2. Install Docker. Idempotent.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }

if command -v docker > /dev/null; then
  echo "Docker already installed: $(docker --version)"
else
  echo "== Installing Docker =="
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi
systemctl enable --now docker
docker version --format 'server {{.Server.Version}}'
