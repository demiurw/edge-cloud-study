#!/bin/bash
# =============================================================================
# capture_client_baseline.sh — Capture Client Idle Baseline Energy Measurements
# =============================================================================
# Runs PowerStat and Scaphandre at idle for 60 seconds to establish
# a baseline energy profile for the CLIENT machine.
# Results are inserted into the client_energy_baselines table.
#
# Usage:
#   sudo bash capture_client_baseline.sh --session-id <id> \
#        --environment <edge|cloud> --workload-type <type>
# =============================================================================

set -euo pipefail

# --- Project paths (absolute) ---
PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
DB_PATH="$PROJECT_DIR/data/results.db"
LOGS_POWERSTAT="$PROJECT_DIR/logs/powerstat"
LOGS_SCAPHANDRE="$PROJECT_DIR/logs/scaphandre"
UTILS_DIR="$PROJECT_DIR/scripts/utils"

BASELINE_DURATION=60  # seconds

# --- Parse arguments ---
SESSION_ID=""
ENVIRONMENT=""
WORKLOAD_TYPE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --environment) ENVIRONMENT="$2"; shift 2 ;;
        --workload-type) WORKLOAD_TYPE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SESSION_ID" ]] || [[ -z "$ENVIRONMENT" ]]; then
    echo "ERROR: --session-id and --environment are required"
    exit 1
fi

if [[ -z "$WORKLOAD_TYPE" ]]; then
    WORKLOAD_TYPE="idle"
fi

# --- Ensure log directories exist ---
mkdir -p "$LOGS_POWERSTAT" "$LOGS_SCAPHANDRE"

TIMESTAMP=$(date -Iseconds)
echo "============================================"
echo "  Client Baseline Capture: $SESSION_ID"
echo "  Environment:      $ENVIRONMENT"
echo "  Workload Type:    $WORKLOAD_TYPE"
echo "  Duration:         ${BASELINE_DURATION}s"
echo "  Timestamp:        $TIMESTAMP"
echo "============================================"

# --- Get idle CPU % ---
echo "[1/3] Measuring idle CPU..."
IDLE_CPU=$(python3 -c "
import psutil, time
readings = []
for _ in range(5):
    readings.append(psutil.cpu_percent(interval=1))
avg = sum(readings) / len(readings)
print(f'{avg:.2f}')
")
echo "  Idle CPU: ${IDLE_CPU}%"

# --- Run PowerStat ---
echo "[2/3] Running PowerStat for ${BASELINE_DURATION}s..."
POWERSTAT_LOG="$LOGS_POWERSTAT/${SESSION_ID}_client_baseline_${ENVIRONMENT}.log"
powerstat -R -z -d 0 1 3600 > "$POWERSTAT_LOG" 2>&1 &
POWERSTAT_PID=$!

# --- Run Scaphandre ---
echo "[3/3] Running Scaphandre for ${BASELINE_DURATION}s..."
SCAPHANDRE_LOG="$LOGS_SCAPHANDRE/${SESSION_ID}_client_baseline_${ENVIRONMENT}.json"
timeout "${BASELINE_DURATION}" scaphandre json -s 1 -f "$SCAPHANDRE_LOG" > /dev/null 2>&1 &
SCAPHANDRE_PID=$!

# --- Wait for measurements to complete ---
echo "  Waiting ${BASELINE_DURATION}s for measurements..."
sleep "$BASELINE_DURATION"

# Kill any remaining background processes
kill "$POWERSTAT_PID" 2>/dev/null || true
kill "$SCAPHANDRE_PID" 2>/dev/null || true
wait "$POWERSTAT_PID" 2>/dev/null || true
wait "$SCAPHANDRE_PID" 2>/dev/null || true

# --- Parse results ---
echo ""
echo "Parsing energy data..."

# Parse PowerStat
POWERSTAT_RESULT=$(python3 "$UTILS_DIR/parse_powerstat.py" "$POWERSTAT_LOG" --duration "$BASELINE_DURATION" --json-output 2>/dev/null || echo '{"avg_watts": 0, "total_joules": 0}')
POWERSTAT_WATTS=$(echo "$POWERSTAT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('avg_watts', 0))")
POWERSTAT_JOULES=$(echo "$POWERSTAT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

# Parse Scaphandre
SCAPHANDRE_RESULT=$(python3 "$UTILS_DIR/parse_scaphandre.py" "$SCAPHANDRE_LOG" --json-output 2>/dev/null || echo '{"avg_watts": 0, "total_joules": 0}')
SCAPHANDRE_WATTS=$(echo "$SCAPHANDRE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('avg_watts', 0))")

# Calculate baseline energy
BASELINE_ENERGY="$POWERSTAT_JOULES"

# --- Insert into SQLite ---
echo "Inserting baseline into database..."
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

# --- Print summary ---
echo ""
echo "Client baseline captured for $ENVIRONMENT environment"
echo "Idle power (Scaphandre): ${SCAPHANDRE_WATTS} W"
echo "Idle power (PowerStat):  ${POWERSTAT_WATTS} W"
echo "Idle CPU:                ${IDLE_CPU} %"
echo "Baseline energy (${BASELINE_DURATION}s):   ${BASELINE_ENERGY} J"
echo ""
echo "Baseline recorded in client_energy_baselines table."
