#!/bin/bash
# =============================================================================
# capture_baseline.sh — Capture Idle Baseline Energy Measurements
# =============================================================================
# Runs PowerStat, Scaphandre, and PowerTOP at idle for 60 seconds to establish
# a baseline energy profile. Results are inserted into the edge_baselines table.
#
# Usage:
#   sudo bash capture_baseline.sh --session-id <id> --workload-type <type>
# =============================================================================

set -euo pipefail

# --- Project paths (absolute) ---
PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
DB_PATH="$PROJECT_DIR/data/results.db"
LOGS_POWERSTAT="$PROJECT_DIR/logs/powerstat"
LOGS_SCAPHANDRE="$PROJECT_DIR/logs/scaphandre"
LOGS_POWERTOP="$PROJECT_DIR/logs/powertop"
UTILS_DIR="$PROJECT_DIR/scripts/utils"

BASELINE_DURATION=60  # seconds

# --- Parse arguments ---
SESSION_ID=""
WORKLOAD_TYPE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --workload-type) WORKLOAD_TYPE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SESSION_ID" ]]; then
    echo "ERROR: --session-id is required"
    exit 1
fi

if [[ -z "$WORKLOAD_TYPE" ]]; then
    WORKLOAD_TYPE="idle"
fi

# --- Ensure log directories exist ---
mkdir -p "$LOGS_POWERSTAT" "$LOGS_SCAPHANDRE" "$LOGS_POWERTOP"

TIMESTAMP=$(date -Iseconds)
echo "============================================"
echo "  Baseline Capture: $SESSION_ID"
echo "  Workload Type:    $WORKLOAD_TYPE"
echo "  Duration:         ${BASELINE_DURATION}s"
echo "  Timestamp:        $TIMESTAMP"
echo "============================================"

# --- Get idle CPU % ---
echo "[1/4] Measuring idle CPU..."
IDLE_CPU=$(python3 -c "
import psutil, time
readings = []
for _ in range(5):
    readings.append(psutil.cpu_percent(interval=1))
avg = sum(readings) / len(readings)
print(f'{avg:.2f}')
")
echo "  Idle CPU: ${IDLE_CPU}%"

# --- Get dominant idle processes ---
DOMINANT_PROCS=$(ps aux --sort=-%cpu | head -6 | tail -5 | awk '{print $11}' | tr '\n' ',' | sed 's/,$//')
echo "  Top processes: $DOMINANT_PROCS"

# --- Run PowerStat ---
echo "[2/4] Running PowerStat for ${BASELINE_DURATION}s..."
POWERSTAT_LOG="$LOGS_POWERSTAT/${SESSION_ID}_baseline.log"
powerstat -R -z -d 0 1 3600 > "$POWERSTAT_LOG" 2>&1 &
POWERSTAT_PID=$!

# --- Run Scaphandre ---
echo "[3/4] Running Scaphandre for ${BASELINE_DURATION}s..."
SCAPHANDRE_LOG="$LOGS_SCAPHANDRE/${SESSION_ID}_baseline.json"
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

# --- Run PowerTOP (snapshot) ---
echo "[4/4] Running PowerTOP report..."
POWERTOP_LOG="$LOGS_POWERTOP/${SESSION_ID}_baseline.csv"
powertop --csv="$POWERTOP_LOG" --time=5 > /dev/null 2>&1 || echo "  PowerTOP warning: may require root"

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
sqlite3 "$DB_PATH" "INSERT INTO edge_baselines (
    session_id, timestamp, workload_type,
    idle_power_scaphandre_w, idle_power_powerstat_w,
    idle_cpu_percent, baseline_duration_seconds,
    baseline_energy_joules, dominant_idle_processes
) VALUES (
    '$SESSION_ID', '$TIMESTAMP', '$WORKLOAD_TYPE',
    $SCAPHANDRE_WATTS, $POWERSTAT_WATTS,
    $IDLE_CPU, $BASELINE_DURATION,
    $BASELINE_ENERGY, '$DOMINANT_PROCS'
);"

# --- Print summary ---
echo ""
echo "============================================"
echo "  BASELINE CAPTURE COMPLETE"
echo "============================================"
echo "  Session:            $SESSION_ID"
echo "  Idle CPU:           ${IDLE_CPU}%"
echo "  PowerStat:          ${POWERSTAT_WATTS} W avg"
echo "  Scaphandre:         ${SCAPHANDRE_WATTS} W avg"
echo "  Baseline Energy:    ${BASELINE_ENERGY} J (over ${BASELINE_DURATION}s)"
echo "  Top idle processes: $DOMINANT_PROCS"
echo "  Logs:"
echo "    PowerStat:  $POWERSTAT_LOG"
echo "    Scaphandre: $SCAPHANDRE_LOG"
echo "    PowerTOP:   $POWERTOP_LOG"
echo "============================================"
echo ""
echo "Baseline recorded in edge_baselines table."
