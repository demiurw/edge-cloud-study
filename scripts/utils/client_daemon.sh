#!/bin/bash
# =============================================================================
# client_daemon.sh — Client Energy Measurement Controller (runs on Machine B)
# =============================================================================
# Persistent measurement controller. Called via SSH from Machine A.
# Starts/stops Scaphandre and PowerStat, parses results, prints JSON.
# Does NOT write to the SQLite database — Machine A handles all DB inserts.
#
# Commands:
#   start   --session-id ID --environment ENV --workload WL --size SZ --run-number N
#   stop
#   baseline --session-id ID --environment ENV --workload-type WL
# =============================================================================

set -euo pipefail

STUDY_DIR="$HOME/edge_cloud_study"
SCAPH_LOGS="$STUDY_DIR/logs/scaphandre"
PSTAT_LOGS="$STUDY_DIR/logs/powerstat"
TMP_DIR="$STUDY_DIR/tmp"
STATE_FILE="$TMP_DIR/measurement_state.json"

COMMAND="${1:-}"
shift || true

# ---------------------------------------------------------------------------
case "$COMMAND" in

# ── START ──────────────────────────────────────────────────────────────────
start)
    SESSION_ID=""
    ENVIRONMENT=""
    WORKLOAD=""
    SIZE="small"
    RUN_NUMBER=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --session-id)   SESSION_ID="$2";   shift 2 ;;
            --environment)  ENVIRONMENT="$2";  shift 2 ;;
            --workload)     WORKLOAD="$2";     shift 2 ;;
            --size)         SIZE="$2";         shift 2 ;;
            --run-number)   RUN_NUMBER="$2";   shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$SESSION_ID" || -z "$ENVIRONMENT" || -z "$WORKLOAD" ]]; then
        echo "ERROR: --session-id, --environment, --workload required" >&2
        exit 1
    fi

    # Kill any stale monitors from a previous run
    sudo pkill -x scaphandre 2>/dev/null || true
    sudo pkill -x powerstat  2>/dev/null || true
    sleep 1

    BASE_NAME="${SESSION_ID}_${ENVIRONMENT}_${WORKLOAD}"
    SCAPH_LOG="$SCAPH_LOGS/${BASE_NAME}.json"
    PSTAT_LOG="$PSTAT_LOGS/${BASE_NAME}.log"

    # Remove stale log files
    rm -f "$SCAPH_LOG" "$PSTAT_LOG"

    # Start monitors in the background
    sudo scaphandre json -s 1 -f "$SCAPH_LOG" > /dev/null 2>&1 &
    SCAPH_PID=$!
    sudo powerstat -R -z -d 0 1 3600 > "$PSTAT_LOG" 2>&1 &
    PSTAT_PID=$!

    START_TIME=$(date -Iseconds)

    # Write state file so stop can recover metadata
    python3 - << PYEOF
import json
state = {
    "status":       "running",
    "start_time":   "$START_TIME",
    "session_id":   "$SESSION_ID",
    "environment":  "$ENVIRONMENT",
    "workload":     "$WORKLOAD",
    "size":         "$SIZE",
    "run_number":   $RUN_NUMBER,
    "scaph_pid":    $SCAPH_PID,
    "pstat_pid":    $PSTAT_PID,
    "scaph_log":    "$SCAPH_LOG",
    "pstat_log":    "$PSTAT_LOG",
}
with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF

    echo "MEASUREMENT_STARTED"
    ;;

# ── STOP ───────────────────────────────────────────────────────────────────
stop)
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"error": "No measurement state found — was start called?"}' >&2
        exit 1
    fi

    STOP_TIME=$(date -Iseconds)

    # Read saved state
    SESSION_ID=$(python3  -c "import json; print(json.load(open('$STATE_FILE'))['session_id'])")
    ENVIRONMENT=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['environment'])")
    WORKLOAD=$(python3    -c "import json; print(json.load(open('$STATE_FILE'))['workload'])")
    SIZE=$(python3        -c "import json; print(json.load(open('$STATE_FILE'))['size'])")
    RUN_NUMBER=$(python3  -c "import json; print(json.load(open('$STATE_FILE'))['run_number'])")
    START_TIME=$(python3  -c "import json; print(json.load(open('$STATE_FILE'))['start_time'])")
    SCAPH_LOG=$(python3   -c "import json; print(json.load(open('$STATE_FILE'))['scaph_log'])")
    PSTAT_LOG=$(python3   -c "import json; print(json.load(open('$STATE_FILE'))['pstat_log'])")

    # Stop monitors
    sudo pkill -x scaphandre 2>/dev/null || true
    sudo pkill -x powerstat  2>/dev/null || true
    sleep 1

    # Calculate duration
    DURATION=$(python3 - << PYEOF
from datetime import datetime
start = datetime.fromisoformat("$START_TIME")
stop  = datetime.fromisoformat("$STOP_TIME")
print((stop - start).total_seconds())
PYEOF
)

    # Parse Scaphandre
    SCAPH_JSON=$(python3 "$STUDY_DIR/parse_scaphandre.py" "$SCAPH_LOG" --json-output \
                 2>/dev/null || echo '{"total_joules":0,"avg_watts":0,"peak_cpu_percent":0,"avg_cpu_percent":0}')
    SCAPH_JOULES=$(echo "$SCAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")
    CPU_PEAK=$(echo     "$SCAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('peak_cpu_percent', 0))")
    CPU_AVG=$(echo      "$SCAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('avg_cpu_percent', 0))")

    # Parse PowerStat
    PSTAT_JSON=$(python3 "$STUDY_DIR/parse_powerstat.py" "$PSTAT_LOG" \
                 --duration "$DURATION" --json-output \
                 2>/dev/null || echo '{"total_joules":0,"avg_watts":0}')
    PSTAT_JOULES=$(echo "$PSTAT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

    # Clean up state file (keep logs for forensics)
    rm -f "$STATE_FILE"

    # Emit JSON summary to stdout — Machine A reads and inserts into DB
    python3 - << PYEOF
import json
summary = {
    "session_id":        "$SESSION_ID",
    "environment":       "$ENVIRONMENT",
    "workload":          "$WORKLOAD",
    "size":              "$SIZE",
    "run_number":        int("$RUN_NUMBER"),
    "start_time":        "$START_TIME",
    "stop_time":         "$STOP_TIME",
    "duration_seconds":  float("$DURATION"),
    "scaphandre_joules": float("$SCAPH_JOULES"),
    "powerstat_joules":  float("$PSTAT_JOULES"),
    "cpu_peak_percent":  float("$CPU_PEAK"),
    "cpu_avg_percent":   float("$CPU_AVG"),
}
print(json.dumps(summary))
PYEOF
    ;;

# ── BASELINE ───────────────────────────────────────────────────────────────
baseline)
    SESSION_ID=""
    ENVIRONMENT=""
    WORKLOAD_TYPE="idle"
    BASELINE_DURATION=60

    while [[ $# -gt 0 ]]; do
        case $1 in
            --session-id)    SESSION_ID="$2";    shift 2 ;;
            --environment)   ENVIRONMENT="$2";   shift 2 ;;
            --workload-type) WORKLOAD_TYPE="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    SCAPH_LOG="$TMP_DIR/baseline_${SESSION_ID}_${ENVIRONMENT}.json"
    PSTAT_LOG="$TMP_DIR/baseline_${SESSION_ID}_${ENVIRONMENT}.log"

    # Kill any stale monitors
    sudo pkill -x scaphandre 2>/dev/null || true
    sudo pkill -x powerstat  2>/dev/null || true
    sleep 1

    # Run monitors for BASELINE_DURATION seconds
    sudo powerstat -R -z -d 0 1 3600 > "$PSTAT_LOG" 2>&1 &
    PSTAT_PID=$!
    sudo scaphandre json -s 1 -f "$SCAPH_LOG" > /dev/null 2>&1 &
    SCAPH_PID=$!

    sleep "$BASELINE_DURATION"

    # Stop monitors
    sudo pkill -x scaphandre 2>/dev/null || true
    sudo pkill -x powerstat  2>/dev/null || true
    wait "$PSTAT_PID" 2>/dev/null || true
    wait "$SCAPH_PID" 2>/dev/null || true

    # Measure idle CPU
    IDLE_CPU=$(python3 - << PYEOF
import psutil, time
readings = [psutil.cpu_percent(interval=1) for _ in range(5)]
print(round(sum(readings) / len(readings), 2))
PYEOF
)

    # Parse Scaphandre
    SCAPH_JSON=$(python3 "$STUDY_DIR/parse_scaphandre.py" "$SCAPH_LOG" --json-output \
                 2>/dev/null || echo '{"avg_watts":0,"total_joules":0}')
    SCAPH_WATTS=$(echo  "$SCAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('avg_watts', 0))")
    SCAPH_JOULES=$(echo "$SCAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

    # Parse PowerStat
    PSTAT_JSON=$(python3 "$STUDY_DIR/parse_powerstat.py" "$PSTAT_LOG" \
                 --duration "$BASELINE_DURATION" --json-output \
                 2>/dev/null || echo '{"avg_watts":0,"total_joules":0}')
    PSTAT_WATTS=$(echo  "$PSTAT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('avg_watts', 0))")
    PSTAT_JOULES=$(echo "$PSTAT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

    # baseline_energy_joules = powerstat total (more reliable for plug-in machines)
    BASELINE_ENERGY="$PSTAT_JOULES"

    # Clean up temp logs
    rm -f "$SCAPH_LOG" "$PSTAT_LOG"

    # Emit JSON summary to stdout
    python3 - << PYEOF
import json
summary = {
    "idle_power_scaphandre_w": float("$SCAPH_WATTS"),
    "idle_power_powerstat_w":  float("$PSTAT_WATTS"),
    "idle_cpu_percent":        float("$IDLE_CPU"),
    "baseline_energy_joules":  float("$BASELINE_ENERGY"),
}
print(json.dumps(summary))
PYEOF
    ;;

# ── UNKNOWN ────────────────────────────────────────────────────────────────
*)
    echo "Usage: client_daemon.sh <start|stop|baseline> [options]" >&2
    echo "  start   --session-id ID --environment ENV --workload WL [--size SZ] [--run-number N]" >&2
    echo "  stop" >&2
    echo "  baseline --session-id ID --environment ENV [--workload-type WL]" >&2
    exit 1
    ;;
esac
