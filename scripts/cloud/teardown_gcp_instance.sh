#!/bin/bash
# =============================================================================
# teardown_gcp_instance.sh — Destroy GCP Compute Engine Instance
# =============================================================================
# Requires explicit user confirmation before destroying the instance.
#
# Usage:
#   bash teardown_gcp_instance.sh --project-id <id> --zone <zone>
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
MEMORY_FILE="$PROJECT_DIR/AGENT_MEMORY.json"

# --- Parse arguments ---
PROJECT_ID=""
ZONE=""
FORCE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --project-id) PROJECT_ID="$2"; shift 2 ;;
        --zone) ZONE="$2"; shift 2 ;;
        --force) FORCE=1; shift 1 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$PROJECT_ID" ]] || [[ -z "$ZONE" ]]; then
    echo "ERROR: --project-id and --zone are required"
    exit 1
fi

# --- Check pending workloads ---
PENDING=$(python3 -c "
import json, sys
try:
    with open('$MEMORY_FILE') as f:
        mem = json.load(f)
    pending = mem.get('experiment', {}).get('workloads_pending', [])
    if pending:
        print(', '.join(pending))
except:
    pass
")

if [[ -n "$PENDING" ]] && [[ $FORCE -eq 0 ]]; then
    echo "ABORT: The following workloads have not been run yet: $PENDING"
    echo "Complete all workload batches before destroying the instance."
    echo "To override this safety check, pass --force flag."
    exit 1
fi

# --- Get instance info ---
echo "Fetching instance info..."
INSTANCE_INFO=$(gcloud compute instances describe edgecloud-server \
    --zone="$ZONE" --project="$PROJECT_ID" --format=json 2>/dev/null || echo '{}')

INSTANCE_ID=$(echo "$INSTANCE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','unknown'))" 2>/dev/null || echo "unknown")
EXTERNAL_IP=$(echo "$INSTANCE_INFO" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for iface in data.get('networkInterfaces', []):
    for ac in iface.get('accessConfigs', []):
        if ac.get('natIP'):
            print(ac['natIP'])
            break
" 2>/dev/null || echo "unknown")

echo ""
echo "============================================"
echo "  WARNING: GCP INSTANCE DESTRUCTION"
echo "============================================"
echo "  Instance: edgecloud-server"
echo "  ID:       $INSTANCE_ID"
echo "  IP:       $EXTERNAL_IP"
echo "  Zone:     $ZONE"
echo "  Project:  $PROJECT_ID"
echo "============================================"
echo ""
read -p "Type 'CONFIRM DESTROY' to proceed: " CONFIRM

if [[ "$CONFIRM" != "CONFIRM DESTROY" ]]; then
    echo "Aborted. Instance NOT destroyed."
    exit 0
fi

# --- Destroy instance ---
echo "Destroying instance edgecloud-server..."
gcloud compute instances delete edgecloud-server \
    --zone="$ZONE" --project="$PROJECT_ID" --quiet

echo "Removing firewall rule allow-iperf3..."
gcloud compute firewall-rules delete allow-iperf3 \
    --project="$PROJECT_ID" --quiet 2>/dev/null || echo "  Firewall rule already removed."

TIMESTAMP=$(date -Iseconds)

# --- Update AGENT_MEMORY.json ---
python3 << PYEOF
import json
with open("$MEMORY_FILE", "r") as f:
    mem = json.load(f)

mem["environment"]["gcp_instance_ip"] = None
mem["environment"]["gcp_instance_id"] = None
mem["environment"]["cloud_droplet_ready"] = False
mem["notes"].append(f"GCP instance edgecloud-server destroyed at $TIMESTAMP")

with open("$MEMORY_FILE", "w") as f:
    json.dump(mem, f, indent=2)
PYEOF

echo ""
echo "============================================"
echo "  GCP INSTANCE DESTROYED"
echo "============================================"
echo "  Timestamp: $TIMESTAMP"
echo "  AGENT_MEMORY.json updated."
echo "============================================"
