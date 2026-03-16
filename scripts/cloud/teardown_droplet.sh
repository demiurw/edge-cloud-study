#!/bin/bash
# =============================================================================
# teardown_droplet.sh — Destroy DigitalOcean Droplet
# =============================================================================
# Requires explicit user confirmation before destroying the Droplet.
#
# Usage:
#   bash teardown_droplet.sh --api-token <token> --droplet-id <id>
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
MEMORY_FILE="$PROJECT_DIR/AGENT_MEMORY.json"

# --- Parse arguments ---
API_TOKEN=""
DROPLET_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --api-token) API_TOKEN="$2"; shift 2 ;;
        --droplet-id) DROPLET_ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$API_TOKEN" ]] || [[ -z "$DROPLET_ID" ]]; then
    echo "ERROR: --api-token and --droplet-id are required"
    exit 1
fi

# --- Get Droplet info ---
echo "Fetching Droplet info..."
INFO=$(curl -s \
    "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" \
    -H "Authorization: Bearer $API_TOKEN")

DROPLET_NAME=$(echo "$INFO" | jq -r '.droplet.name')
DROPLET_IP=$(echo "$INFO" | jq -r '.droplet.networks.v4[] | select(.type=="public") | .ip_address' | head -1)
DROPLET_REGION=$(echo "$INFO" | jq -r '.droplet.region.slug')

echo ""
echo "============================================"
echo "  WARNING: DROPLET DESTRUCTION"
echo "============================================"
echo "  ID:      $DROPLET_ID"
echo "  Name:    $DROPLET_NAME"
echo "  IP:      $DROPLET_IP"
echo "  Region:  $DROPLET_REGION"
echo "============================================"
echo ""
read -p "Type 'CONFIRM DESTROY' to proceed: " CONFIRM

if [[ "$CONFIRM" != "CONFIRM DESTROY" ]]; then
    echo "Aborted. Droplet NOT destroyed."
    exit 0
fi

# --- Destroy Droplet ---
echo "Destroying Droplet $DROPLET_ID..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" \
    -H "Authorization: Bearer $API_TOKEN")

if [[ "$RESPONSE" == "204" ]]; then
    TIMESTAMP=$(date -Iseconds)
    echo "Droplet $DROPLET_ID destroyed successfully at $TIMESTAMP"

    # Update AGENT_MEMORY.json
    python3 << PYEOF
import json
with open("$MEMORY_FILE", "r") as f:
    mem = json.load(f)
mem["environment"]["cloud_droplet_ready"] = False
mem["notes"].append(f"Droplet $DROPLET_ID destroyed at $TIMESTAMP")
with open("$MEMORY_FILE", "w") as f:
    json.dump(mem, f, indent=2)
PYEOF

    echo "AGENT_MEMORY.json updated."
else
    echo "ERROR: Failed to destroy Droplet. HTTP status: $RESPONSE"
    exit 1
fi
