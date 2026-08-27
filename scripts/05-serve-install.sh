#!/usr/bin/env bash
# Step 5. Install the systemd service and start it.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p /opt/muse /root/.cache/vllm
[ -f /opt/muse/env ] || install -m 644 "$SRC/config/muse.env" /opt/muse/env
install -m 755 "$SRC/config/serve.sh"   /opt/muse/serve.sh
install -m 755 "$SRC/scripts/smoke.sh"  /opt/muse/smoke.sh
install -m 755 "$SRC/scripts/bench.sh"  /opt/muse/bench.sh
install -m 644 "$SRC/config/muse-glimmer.service" /etc/systemd/system/muse-glimmer.service

systemctl daemon-reload
systemctl enable --now muse-glimmer

echo "== Waiting for the server (first start compiles kernels; 5-15 min) =="
for i in $(seq 1 150); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health 2>/dev/null || true)
  # 401 also proves it is up, once an API key is configured.
  if [ "$code" = "200" ] || [ "$code" = "401" ]; then echo "Server ready (health=$code)."; exit 0; fi
  # "systemctl is-active" returns non-zero for "activating" too, so only bail
  # on a genuinely terminal state.
  state=$(systemctl is-active muse-glimmer || true)
  case "$state" in
    failed|inactive) echo "Service $state. Check: journalctl -u muse-glimmer -n 60"; exit 1 ;;
  esac
  sleep 10
done
echo "Timed out. Check: journalctl -u muse-glimmer -f"; exit 1
