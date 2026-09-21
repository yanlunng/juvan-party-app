#!/usr/bin/env bash
# Deploy/update Juvan's party app on a Compute Engine VM.
#
# Run this from Google Cloud Shell (https://shell.cloud.google.com) — gcloud
# is already installed and authenticated there, and this machine's local
# network only allows a narrow set of domains outright (confirmed via curl:
# most external hosts fail, including google.com and duckdns.org), so a
# local gcloud install/login and DNS testing won't work from here. In Cloud
# Shell:
#   1. Upload this whole juvan-party-app/ folder (Cloud Shell Editor's
#      upload button, or `git clone` if you push the repo somewhere first).
#   2. cd juvan-party-app
#   3. Run the command below.
#
# Usage:
#   export GCP_PROJECT_ID=my-project
#   export ADMIN_PASSWORD='pick-a-real-password'
#   export ENTRY_PASSWORD='pick-a-real-password'   # gates the Getting Here / entry QR page
#   ./deploy/deploy.sh
#
# Optional: point a free DuckDNS (duckdns.org) subdomain at the VM's static
# IP by also setting:
#   DUCKDNS_DOMAIN=juvan-party.duckdns.org   # the subdomain you created
#   DUCKDNS_TOKEN=...                        # your account token from duckdns.org
# If either is unset, the DNS step is skipped and you just get the raw IP
# over plain HTTP. If both are set, the script also installs Caddy as a
# reverse proxy in front of the app, which automatically gets and renews a
# free Let's Encrypt HTTPS certificate for that domain — no DuckDNS setting
# gives you HTTPS by itself, a domain name and a TLS certificate are two
# separate things, so this is the step that actually fixes "Not secure".
#
# Safe to re-run: it only creates the IP/firewall/VM if they don't already
# exist, and re-running just pushes the latest server.py/public/ and
# restarts the service. It never touches the VM's data/ or uploads/
# directories, so the guestbook and leaderboards survive redeploys.

set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID to your GCP project id}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?Set ADMIN_PASSWORD to the password for the admin panel}"
ENTRY_PASSWORD="${ENTRY_PASSWORD:?Set ENTRY_PASSWORD to the password guests use to unlock Getting Here / entry QR code}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
INSTANCE_NAME="${INSTANCE_NAME:-juvan-party-app}"
STATIC_IP_NAME="${STATIC_IP_NAME:-juvan-party-ip}"
FIREWALL_RULE="${FIREWALL_RULE:-allow-juvan-party-http}"
TAG="juvan-party"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Using project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

echo "==> Enabling Compute Engine API (no-op if already enabled)"
gcloud services enable compute.googleapis.com

echo "==> Reserving static external IP (idempotent)"
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region "$REGION" &>/dev/null; then
  gcloud compute addresses create "$STATIC_IP_NAME" --region "$REGION"
fi
STATIC_IP="$(gcloud compute addresses describe "$STATIC_IP_NAME" --region "$REGION" --format='get(address)')"
echo "    Static IP: $STATIC_IP"

if [[ -n "${DUCKDNS_DOMAIN:-}" && -n "${DUCKDNS_TOKEN:-}" ]]; then
  DUCKDNS_SUBDOMAIN="${DUCKDNS_DOMAIN%.duckdns.org}"
  echo "==> Updating DuckDNS ($DUCKDNS_DOMAIN -> $STATIC_IP)"
  DUCKDNS_RESPONSE="$(curl -fsS "https://www.duckdns.org/update?domains=$DUCKDNS_SUBDOMAIN&token=$DUCKDNS_TOKEN&ip=$STATIC_IP" || echo "ERROR")"
  if [[ "$DUCKDNS_RESPONSE" != "OK" ]]; then
    echo "    Warning: DuckDNS update returned '$DUCKDNS_RESPONSE' (expected OK) — check DUCKDNS_DOMAIN/DUCKDNS_TOKEN. Continuing without it."
  fi
  echo ""
  APP_PORT=8090
else
  echo "==> Skipping DuckDNS update (set DUCKDNS_DOMAIN and DUCKDNS_TOKEN to enable)"
  APP_PORT=80
fi

echo "==> Ensuring firewall rule for HTTP/HTTPS (tcp:80,443)"
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" &>/dev/null; then
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --allow=tcp:80,tcp:443 \
    --target-tags="$TAG" \
    --direction=INGRESS \
    --description="Allow HTTP/HTTPS to Juvan's party app"
else
  gcloud compute firewall-rules update "$FIREWALL_RULE" --allow=tcp:80,tcp:443
fi

echo "==> Ensuring VM exists"
if ! gcloud compute instances describe "$INSTANCE_NAME" --zone "$ZONE" &>/dev/null; then
  gcloud compute instances create "$INSTANCE_NAME" \
    --zone "$ZONE" \
    --machine-type "$MACHINE_TYPE" \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --tags="$TAG" \
    --address="$STATIC_IP" \
    --metadata=startup-script='#!/bin/bash
set -e
apt-get update -y
apt-get install -y python3
id -u partyapp &>/dev/null || useradd -r -s /usr/sbin/nologin -m -d /opt/juvan-party-app partyapp
mkdir -p /opt/juvan-party-app/data /opt/juvan-party-app/uploads
chown -R partyapp:partyapp /opt/juvan-party-app
'
  echo "    Waiting for the VM to boot and finish its startup script..."
  sleep 45
else
  echo "    VM already exists, skipping create."
fi

remote_ssh() {
  gcloud compute ssh "$INSTANCE_NAME" --zone "$ZONE" --command "$1"
}

echo "==> Waiting for SSH to be ready"
for i in $(seq 1 10); do
  if remote_ssh "echo ok" &>/dev/null; then
    break
  fi
  echo "    retry $i/10..."
  sleep 10
done

echo "==> Syncing app code (server.py + public/)"
gcloud compute scp --zone "$ZONE" --recurse \
  "$APP_DIR/server.py" "$APP_DIR/public" \
  "$INSTANCE_NAME":/tmp/juvan-party-app-src

remote_ssh "
  sudo mkdir -p /opt/juvan-party-app
  sudo rm -rf /opt/juvan-party-app/public /opt/juvan-party-app/server.py
  sudo mv /tmp/juvan-party-app-src/server.py /opt/juvan-party-app/server.py
  sudo mv /tmp/juvan-party-app-src/public /opt/juvan-party-app/public
  sudo mkdir -p /opt/juvan-party-app/data /opt/juvan-party-app/uploads
  sudo chown -R partyapp:partyapp /opt/juvan-party-app
"

echo "==> Writing environment file (contains the admin/entry passwords, not committed to git)"
TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT
cat > "$TMP_ENV" <<EOF
HOST=0.0.0.0
PORT=$APP_PORT
ADMIN_PASSWORD=$ADMIN_PASSWORD
ENTRY_PASSWORD=$ENTRY_PASSWORD
EOF
gcloud compute scp --zone "$ZONE" "$TMP_ENV" "$INSTANCE_NAME":/tmp/party.env
remote_ssh "
  sudo mv /tmp/party.env /opt/juvan-party-app/party.env
  sudo chown partyapp:partyapp /opt/juvan-party-app/party.env
  sudo chmod 600 /opt/juvan-party-app/party.env
"

echo "==> Installing systemd unit"
gcloud compute scp --zone "$ZONE" "$SCRIPT_DIR/juvan-party.service" "$INSTANCE_NAME":/tmp/juvan-party.service
remote_ssh "
  sudo mv /tmp/juvan-party.service /etc/systemd/system/juvan-party.service
  sudo systemctl daemon-reload
  sudo systemctl enable juvan-party
  sudo systemctl restart juvan-party
  sleep 1
  sudo systemctl --no-pager status juvan-party
"

echo ""
if [[ -n "${DUCKDNS_DOMAIN:-}" ]]; then
  echo "==> Installing Caddy for automatic HTTPS on $DUCKDNS_DOMAIN"
  remote_ssh "
    if ! command -v caddy >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
      sudo apt-get update -y
      sudo apt-get install -y caddy
    fi
    echo '$DUCKDNS_DOMAIN {
      reverse_proxy localhost:$APP_PORT
    }' | sudo tee /etc/caddy/Caddyfile > /dev/null
    sudo systemctl enable caddy
    sudo systemctl restart caddy
  "
fi

echo ""
if [[ -n "${DUCKDNS_DOMAIN:-}" ]]; then
  echo "==> Done. Party app should be live at: https://$DUCKDNS_DOMAIN/ (DNS + first-time cert issuance can take a few minutes)"
  echo "    Admin panel: https://$DUCKDNS_DOMAIN/admin.html"
  echo "    Note: Caddy only answers to $DUCKDNS_DOMAIN — the bare IP ($STATIC_IP) won't serve the app anymore."
else
  echo "==> Done. Party app should be live at: http://$STATIC_IP/"
  echo "    Admin panel: http://$STATIC_IP/admin.html"
fi
