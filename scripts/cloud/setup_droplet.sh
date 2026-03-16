#!/bin/bash
# =============================================================================
# setup_droplet.sh — Create and Configure a DigitalOcean Droplet
# =============================================================================
# Creates a Basic Droplet (1 vCPU, 1GB RAM, Ubuntu 22.04) and installs
# iperf3 and workload tools on it.
#
# Usage:
#   bash setup_droplet.sh --api-token <token> --region <region> --session-id <id>
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
MEMORY_FILE="$PROJECT_DIR/AGENT_MEMORY.json"

# --- Parse arguments ---
API_TOKEN=""
REGION="nyc3"
SESSION_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --api-token) API_TOKEN="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --session-id) SESSION_ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$API_TOKEN" ]] || [[ -z "$SESSION_ID" ]]; then
    echo "ERROR: --api-token and --session-id are required"
    exit 1
fi

DROPLET_NAME="edge-study-${SESSION_ID//_/-}"

echo "============================================"
echo "  Creating DigitalOcean Droplet"
echo "============================================"
echo "  Name:    $DROPLET_NAME"
echo "  Region:  $REGION"
echo "  Size:    s-1vcpu-1gb"
echo "  Image:   ubuntu-22-04-x64"
echo "============================================"

# --- Create Droplet ---
echo "[1/4] Creating Droplet..."
CREATE_RESPONSE=$(curl -s -X POST \
    "https://api.digitalocean.com/v2/droplets" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"$DROPLET_NAME\",
        \"region\": \"$REGION\",
        \"size\": \"s-1vcpu-1gb\",
        \"image\": \"ubuntu-22-04-x64\",
        \"ssh_keys\": [],
        \"backups\": false,
        \"ipv6\": false,
        \"monitoring\": true,
        \"tags\": [\"edge-study\"]
    }")

DROPLET_ID=$(echo "$CREATE_RESPONSE" | jq -r '.droplet.id')

if [[ "$DROPLET_ID" == "null" ]] || [[ -z "$DROPLET_ID" ]]; then
    echo "ERROR: Failed to create Droplet"
    echo "$CREATE_RESPONSE" | jq .
    exit 1
fi

echo "  Droplet ID: $DROPLET_ID"

# --- Wait for Droplet to be active ---
echo "[2/4] Waiting for Droplet to become active..."
for i in $(seq 1 60); do
    STATUS_RESPONSE=$(curl -s \
        "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" \
        -H "Authorization: Bearer $API_TOKEN")
    STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.droplet.status')
    if [[ "$STATUS" == "active" ]]; then
        break
    fi
    echo "  Status: $STATUS (attempt $i/60)..."
    sleep 5
done

# Get IP address
DROPLET_IP=$(echo "$STATUS_RESPONSE" | jq -r '.droplet.networks.v4[] | select(.type=="public") | .ip_address' | head -1)
echo "  Droplet IP: $DROPLET_IP"

if [[ -z "$DROPLET_IP" ]] || [[ "$DROPLET_IP" == "null" ]]; then
    echo "ERROR: Could not get Droplet IP"
    exit 1
fi

# --- Install tools on Droplet ---
echo "[3/4] Installing tools on Droplet..."
sleep 30  # Wait for SSH to be ready

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "root@$DROPLET_IP" << 'REMOTE_SCRIPT'
apt-get update -qq
apt-get install -y -qq iperf3 python3 python3-pip sqlite3 ffmpeg curl
pip3 install flask psutil
# Start iperf3 server
iperf3 -s -D
echo "SETUP_COMPLETE"
REMOTE_SCRIPT

# --- Verify ---
echo "[4/4] Verifying Droplet..."
VERIFY=$(ssh -o StrictHostKeyChecking=no "root@$DROPLET_IP" "iperf3 --version | head -1 && python3 --version && echo VERIFY_OK" 2>&1)
echo "  Verification: $VERIFY"

# --- Update AGENT_MEMORY.json ---
python3 << PYEOF
import json
with open("$MEMORY_FILE", "r") as f:
    mem = json.load(f)
mem["environment"]["do_api_configured"] = True
mem["environment"]["cloud_droplet_ready"] = True
mem["environment"]["cloud_droplet_id"] = "$DROPLET_ID"
mem["environment"]["cloud_droplet_ip"] = "$DROPLET_IP"
mem["environment"]["cloud_droplet_region"] = "$REGION"
with open("$MEMORY_FILE", "w") as f:
    json.dump(mem, f, indent=2)
PYEOF

echo ""
echo "============================================"
echo "  DROPLET READY"
echo "============================================"
echo "  ID:      $DROPLET_ID"
echo "  IP:      $DROPLET_IP"
echo "  Region:  $REGION"
echo "  SSH:     ssh root@$DROPLET_IP"
echo "============================================"
