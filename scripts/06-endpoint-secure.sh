#!/usr/bin/env bash
# Step 6. Expose the server as an HTTPS endpoint with API key auth.
#
#   client --HTTPS + Bearer key--> Caddy :443 --http--> vLLM 127.0.0.1:8000
#
# Optional. Skip it if you only use the model from the machine itself.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"

PUBLIC_IP=${PUBLIC_IP:-$(curl -sS --max-time 10 https://api.ipify.org)}
# nip.io resolves <ip>.nip.io back to <ip>, so Let's Encrypt can issue a normal
# trusted certificate without owning a domain. To use your own domain, point an
# A record at this IP and set VLLM_DOMAIN before running.
VLLM_DOMAIN=${VLLM_DOMAIN:-${PUBLIC_IP}.nip.io}
ACME_EMAIL=${ACME_EMAIL:?Set ACME_EMAIL to your email address}

echo "== Public IP: $PUBLIC_IP"
echo "== Domain:    $VLLM_DOMAIN"

# 1. API key.
mkdir -p /etc/vllm && chmod 700 /etc/vllm
if [ ! -s /etc/vllm/api-key ]; then
  printf 'sk-mi300x-%s' "$(openssl rand -hex 24)" > /etc/vllm/api-key
  chmod 600 /etc/vllm/api-key
  echo "   generated /etc/vllm/api-key"
else
  echo "   reusing existing /etc/vllm/api-key"
fi

# 2. Caddy.
if ! command -v caddy > /dev/null; then
  echo "== Installing Caddy =="
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y caddy
fi

install -m 644 "$SRC/config/Caddyfile" /etc/caddy/Caddyfile
mkdir -p /etc/systemd/system/caddy.service.d
install -m 644 "$SRC/config/caddy-override.conf" /etc/systemd/system/caddy.service.d/override.conf
umask 077
printf 'VLLM_API_KEY=%s\nVLLM_DOMAIN=%s\nACME_EMAIL=%s\n' \
  "$(cat /etc/vllm/api-key)" "$VLLM_DOMAIN" "$ACME_EMAIL" > /etc/caddy/vllm.env
umask 022
chmod 640 /etc/caddy/vllm.env; chown root:caddy /etc/caddy/vllm.env

# 3. Firewall. Allow SSH BEFORE enabling, or you lock yourself out.
echo "== Firewall =="
ufw allow 22/tcp  comment 'SSH'          > /dev/null
ufw allow 80/tcp  comment 'ACME HTTP-01' > /dev/null
ufw allow 443/tcp comment 'HTTPS API'    > /dev/null
ufw default deny incoming  > /dev/null
ufw default allow outgoing > /dev/null
ufw --force enable > /dev/null
ufw status | head -8

# 4. Restart vLLM so it binds loopback and picks up the key, then Caddy.
systemctl daemon-reload
systemctl restart muse-glimmer
echo "== Waiting for vLLM =="
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health || true)
  if [ "$code" = 200 ] || [ "$code" = 401 ]; then break; fi
  state=$(systemctl is-active muse-glimmer || true)
  case "$state" in
    failed|inactive) echo "vLLM $state. Check: journalctl -u muse-glimmer -n 50"; exit 1 ;;
  esac
  sleep 10
done
systemctl enable --now caddy > /dev/null 2>&1 || true
systemctl restart caddy

echo "== Waiting for the certificate =="
for i in $(seq 1 36); do
  journalctl -u caddy --no-pager -n 200 2>/dev/null \
    | grep -q "certificate obtained successfully\|got certificate" && { echo "   certificate obtained"; break; }
  cstate=$(systemctl is-active caddy || true)
  case "$cstate" in
    failed|inactive) echo "Caddy $cstate. Check: journalctl -u caddy -n 40"; exit 1 ;;
  esac
  sleep 5
done

echo
echo "Done. Run ./scripts/client-config.sh to print client setup."
