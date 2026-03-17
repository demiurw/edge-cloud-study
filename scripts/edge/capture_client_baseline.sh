#!/bin/bash
# =============================================================================
# capture_client_baseline.sh — Capture Client Idle Baseline on Machine B
# =============================================================================
# SSH to Machine B and run client_daemon.sh baseline for 60 seconds.
# Inserts the result into client_energy_baselines on Machine A.
#
# Usage:
#   bash capture_client_baseline.sh --session-id <id> \
#        --environment <edge|cloud> [--workload-type <type>]
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
DB_PATH="$PROJECT_DIR/data/results.db"
MEMORY_FILE="$PROJECT_DIR/AGENT_MEMORY.json"

# --- Read Machine B config ---
CLIENT_IP=$(python3   -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_ip'])")
CLIENT_USER=$(python3 -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_user'])")
SSH_KEY=$(python3     -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_ssh_key'])")

SSH_CMD="ssh -o StrictHostKeyChecking=no -i $SSH_KEY ${CLIENT_USER}@${CLIENT_IP}"

BASELINE_DURATION=60

# --- Parse arguments ---
SESSION_ID=""
ENVIRONMENT=""
WORKLOAD_TYPE="idle"

while [[ $# -gt 0 ]]; do
    case $1 in
        --session-id)    SESSION_ID="$2";    shift 2 ;;
        --environment)   ENVIRONMENT="$2";   shift 2 ;;
        --workload-type) WORKLOAD_TYPE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SESSION_ID" || -z "$ENVIRONMENT" ]]; then
    echo "ERROR: --session-id and --environment are required"
    exit 1
fi

TIMESTAMP=$(date -Iseconds)
echo "============================================"
echo "  Client Baseline Capture (Machine B)"
echo "  Session:     $SESSION_ID"
echo "  Environment: $ENVIRONMENT"
echo "  Workload:    $WORKLOAD_TYPE"
echo "  Duration:    ${BASELINE_DURATION}s"
echo "  Client:      ${CLIENT_USER}@${CLIENT_IP}"
echo "============================================"

# --- Verify Machine B is reachable ---
echo "[1/3] Verifying Machine B connectivity..."
if ! $SSH_CMD "echo OK" | grep -q OK; then
    echo "ERROR: Machine B not reachable at $CLIENT_IP"
    exit 1
fi
echo "  Machine B OK."

# --- Run baseline on Machine B (blocks for 60 seconds) ---
echo "[2/3] Running 60-second idle baseline on Machine B..."
BASELINE_JSON=$($SSH_CMD \
    "bash ~/edge_cloud_study/client_daemon.sh baseline \
     --session-id $SESSION_ID \
     --environment $ENVIRONMENT \
     --workload-type $WORKLOAD_TYPE")

echo "  Baseline complete."
echo "  Raw JSON: $BASELINE_JSON"

# --- Parse JSON and extract values ---
SCAPHANDRE_WATTS=$(echo "$BASELINE_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('idle_power_scaphandre_w', 0))")
POWERSTAT_WATTS=$(echo "$BASELINE_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('idle_power_powerstat_w', 0))")
IDLE_CPU=$(echo "$BASELINE_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('idle_cpu_percent', 0))")
BASELINE_ENERGY=$(echo "$BASELINE_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('baseline_energy_joules', 0))")

# --- Insert into SQLite on Machine A ---
echo "[3/3] Inserting baseline into database..."
sqlite3 "$DB_PATH" "INSERT INTO client_energy_baselines (
    session_id, environment, timestamp, workload_type,
    idle_power_scaphandre_w, idle_power_powerstat_w,
    idle_cpu_percent, baseline_duration_seconds,
    baseline_energy_joules
) VALUES (
    '$SESSION_ID', '$ENVIRONMENT', '$TIMESTAMP', '$WORKLOAD_TYPE',
    $SCAPHANDRE_WATTS, $POWERSTAT_WATTS,
    $IDLE_CPU, $BASELINE_DURATION,
    $BASELINE_ENERGY
);"

echo ""
echo "Client baseline captured from Machine B ($CLIENT_IP):"
echo "  Idle power (Scaphandre): ${SCAPHANDRE_WATTS} W"
echo "  Idle power (PowerStat):  ${POWERSTAT_WATTS} W"
echo "  Idle CPU:                ${IDLE_CPU} %"
echo "  Baseline energy (${BASELINE_DURATION}s):   ${BASELINE_ENERGY} J"
echo ""
echo "Baseline recorded in client_energy_baselines table."
