#!/usr/bin/env bash
# Deploy/update Juvan's party app on a Compute Engine VM.
#
# Run this from Google Cloud Shell (https://shell.cloud.google.com) — gcloud
# is already installed and authenticated there, and this machine's corp
# network blocks every Google domain outright (confirmed: google.com,
# accounts.google.com, compute.googleapis.com, console.cloud.google.com all
# 403 from here, even a plain curl), so a local gcloud install/login won't
# work from here. In Cloud Shell:
#   1. Upload this whole juvan-party-app/ folder (Cloud Shell Editor's
#      upload button, or `git clone` if you push the repo somewhere first).
#   2. cd juvan-party-app
#   3. Run the command below.
#
# Usage:
#   GCP_PROJECT_ID=my-project ADMIN_PASSWORD='pick-a-real-password' ./deploy/deploy.sh
#
# Safe to re-run: it only creates the IP/firewall/VM if they don't already
# exist, and re-running just pushes the latest server.py/public/ and
# restarts the service. It never touches the VM's data/ or uploads/
# directories, so the guestbook and leaderboards survive redeploys.

set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID to your GCP project id}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?Set ADMIN_PASSWORD to the password for the admin panel}"
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

echo "==> Ensuring firewall rule for HTTP (tcp:80)"
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" &>/dev/null; then
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --allow=tcp:80 \
    --target-tags="$TAG" \
    --direction=INGRESS \
    --description="Allow HTTP to Juvan's party app"
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

echo "==> Writing environment file (contains the admin password, not committed to git)"
TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT
cat > "$TMP_ENV" <<EOF
HOST=0.0.0.0
PORT=80
ADMIN_PASSWORD=$ADMIN_PASSWORD
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
echo "==> Done. Party app should be live at: http://$STATIC_IP/"
echo "    Admin panel: http://$STATIC_IP/admin.html"
