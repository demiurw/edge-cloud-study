#!/bin/bash
# =============================================================================
# setup_gcp_instance.sh — Provision GCP e2-micro Instance
# =============================================================================
# Creates a GCP Compute Engine instance for cloud workload experiments,
# installs dependencies, and verifies connectivity.
#
# Usage:
#   bash setup_gcp_instance.sh --project-id <id> --region <region> \
#        --zone <zone> --session-id <session>
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
MEMORY_FILE="$PROJECT_DIR/AGENT_MEMORY.json"

# --- Parse arguments ---
PROJECT_ID=""
REGION=""
ZONE=""
SESSION_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --project-id) PROJECT_ID="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --zone) ZONE="$2"; shift 2 ;;
        --session-id) SESSION_ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$PROJECT_ID" ]] || [[ -z "$REGION" ]] || [[ -z "$ZONE" ]]; then
    echo "ERROR: --project-id, --region, and --zone are required"
    exit 1
fi

SESSION_ID="${SESSION_ID:-gcp_setup}"

echo "============================================"
echo "  GCP Instance Setup"
echo "============================================"
echo "  Project:  $PROJECT_ID"
echo "  Region:   $REGION"
echo "  Zone:     $ZONE"
echo "  Session:  $SESSION_ID"
echo "============================================"

# --- Create firewall rule ---
echo "[1/5] Creating firewall rule for iperf3 and HTTP..."
gcloud compute firewall-rules create allow-iperf3 \
    --project="$PROJECT_ID" \
    --allow tcp:5201,udp:5201,tcp:8080 \
    --target-tags=edgecloud-experiment \
    --description="Allow iperf3 and HTTP for edge-cloud experiment" \
    --quiet 2>/dev/null || echo "  Firewall rule already exists, continuing."

# --- Create e2-micro instance ---
echo "[2/5] Creating e2-micro instance..."
gcloud compute instances create edgecloud-server \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type=e2-micro \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=20GB \
    --tags=edgecloud-experiment \
    --metadata=startup-script='#!/bin/bash
apt-get update -qq
apt-get install -y -qq iperf3 python3 python3-pip sqlite3 ffmpeg
pip3 install flask' \
    --quiet

echo "  Waiting 60s for instance to boot and run startup script..."
sleep 60

# --- Get instance details ---
echo "[3/5] Retrieving instance details..."
INSTANCE_INFO=$(gcloud compute instances describe edgecloud-server \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --format=json)

INSTANCE_ID=$(echo "$INSTANCE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
EXTERNAL_IP=$(echo "$INSTANCE_INFO" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for iface in data.get('networkInterfaces', []):
    for ac in iface.get('accessConfigs', []):
        if ac.get('natIP'):
            print(ac['natIP'])
            break
")

echo "  Instance ID: $INSTANCE_ID"
echo "  External IP: $EXTERNAL_IP"

# --- Install dependencies via SSH ---
echo "[4/5] Verifying dependencies on instance..."
gcloud compute ssh edgecloud-server --zone="$ZONE" --project="$PROJECT_ID" \
    --command="which iperf3 && which python3 && which sqlite3 && echo 'DEPS OK'" \
    --quiet 2>/dev/null || {
        echo "  Deps not ready yet, waiting 30s and retrying..."
        sleep 30
        gcloud compute ssh edgecloud-server --zone="$ZONE" --project="$PROJECT_ID" \
            --command="sudo apt-get install -y -qq iperf3 python3 python3-pip sqlite3 ffmpeg && pip3 install flask && echo 'DEPS OK'" \
            --quiet
    }

# --- Test iperf3 connectivity ---
echo "[5/5] Testing iperf3 connectivity..."
gcloud compute ssh edgecloud-server --zone="$ZONE" --project="$PROJECT_ID" \
    --command="pkill iperf3 2>/dev/null; iperf3 -s -D" --quiet 2>/dev/null || true
sleep 2

iperf3 -c "$EXTERNAL_IP" -t 2 -J > /dev/null 2>&1 && echo "  iperf3 connectivity: OK" || echo "  WARNING: iperf3 test failed — check firewall rules"

TIMESTAMP_START=$(date -Iseconds)

# --- Update AGENT_MEMORY.json ---
python3 << PYEOF
import json
with open("$MEMORY_FILE", "r") as f:
    mem = json.load(f)

mem["environment"]["gcp_instance_id"] = "$INSTANCE_ID"
mem["environment"]["gcp_instance_ip"] = "$EXTERNAL_IP"
mem["environment"]["cloud_droplet_ready"] = True
mem["environment"]["gcp_project_id"] = "$PROJECT_ID"
mem["environment"]["gcp_region"] = "$REGION"
mem["environment"]["gcp_instance_start_time"] = "$TIMESTAMP_START"
mem["completed_steps"].append("4.3 GCP e2-micro instance provisioned")
mem["notes"].append(f"GCP instance edgecloud-server created in $ZONE (ID: $INSTANCE_ID, IP: $EXTERNAL_IP)")

with open("$MEMORY_FILE", "w") as f:
    json.dump(mem, f, indent=2)
PYEOF

BOUNDARIES_LOG="$PROJECT_DIR/logs/cloud/workload_boundaries.log"
mkdir -p "$PROJECT_DIR/logs/cloud"
echo "instance_created | $TIMESTAMP_START | $INSTANCE_ID | $ZONE" >> "$BOUNDARIES_LOG"

echo ""
echo "============================================"
echo "  GCP INSTANCE READY"
echo "============================================"
echo "  Instance: edgecloud-server"
echo "  ID:       $INSTANCE_ID"
echo "  IP:       $EXTERNAL_IP"
echo "  Zone:     $ZONE"
echo "  Type:     e2-micro (2 shared vCPU, 1GB RAM)"
echo "============================================"
