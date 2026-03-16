#!/bin/bash
# =============================================================================
# run_workload.sh — Run Edge Workloads with Energy Monitoring
# =============================================================================
# Starts background energy monitors (Scaphandre, PowerStat), runs the
# Containernet topology workload, then parses all logs and inserts results
# into the edge_runs SQLite table.
#
# Usage:
#   sudo bash run_workload.sh --session-id <id> --workload <type> \
#        --size <small|medium|large> --runs <N>
# =============================================================================

set -euo pipefail

# --- Project paths (absolute) ---
PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
DB_PATH="$PROJECT_DIR/data/results.db"
TOPOLOGY_SCRIPT="$PROJECT_DIR/topology/topology.py"
LOGS_POWERSTAT="$PROJECT_DIR/logs/powerstat"
LOGS_SCAPHANDRE="$PROJECT_DIR/logs/scaphandre"
LOGS_POWERTOP="$PROJECT_DIR/logs/powertop"
LOGS_IPERF3="$PROJECT_DIR/logs/iperf3"
EXPORTS_DIR="$PROJECT_DIR/exports"
UTILS_DIR="$PROJECT_DIR/scripts/utils"
MEMORY_FILE="$PROJECT_DIR/AGENT_MEMORY.json"

# --- Parse arguments ---
SESSION_ID=""
WORKLOAD=""
SIZE="small"
RUNS=1000

while [[ $# -gt 0 ]]; do
    case $1 in
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --workload) WORKLOAD="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SESSION_ID" ]] || [[ -z "$WORKLOAD" ]]; then
    echo "ERROR: --session-id and --workload are required"
    echo "Usage: sudo bash run_workload.sh --session-id <id> --workload <type> --size <size> --runs <N>"
    exit 1
fi

# --- Ensure directories exist ---
mkdir -p "$LOGS_POWERSTAT" "$LOGS_SCAPHANDRE" "$LOGS_POWERTOP" "$LOGS_IPERF3" "$EXPORTS_DIR"

# --- Check baseline exists ---
BASELINE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM edge_baselines WHERE session_id='$SESSION_ID';")
if [[ "$BASELINE_COUNT" -eq 0 ]]; then
    echo "WARNING: No baseline captured for session $SESSION_ID"
    echo "Consider running capture_baseline.sh first."
    echo "Continuing anyway..."
fi

SIZE_SUFFIX=""
if [[ "$WORKLOAD" == "file_transfer" ]]; then
    SIZE_SUFFIX="_${SIZE}"
fi

TIMESTAMP_START=$(date -Iseconds)
echo "============================================"
echo "  Edge Workload Run"
echo "============================================"
echo "  Session:    $SESSION_ID"
echo "  Workload:   $WORKLOAD"
echo "  Size:       $SIZE"
echo "  Runs:       $RUNS"
echo "  Started:    $TIMESTAMP_START"
echo "============================================"

# --- Start background energy monitors ---
echo "[1/5] Starting energy monitors..."

# Scaphandre (JSON output, 1-second intervals)
SCAPHANDRE_LOG="$LOGS_SCAPHANDRE/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}.json"
scaphandre json -s 1 -f "$SCAPHANDRE_LOG" > /dev/null 2>&1 &
SCAPHANDRE_PID=$!
echo "  Scaphandre started (PID: $SCAPHANDRE_PID)"

# PowerStat (1-second intervals, run until killed)
POWERSTAT_LOG="$LOGS_POWERSTAT/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}.log"
powerstat -R -z -d 0 1 3600 > "$POWERSTAT_LOG" 2>&1 &
POWERSTAT_PID=$!
echo "  PowerStat started (PID: $POWERSTAT_PID)"

# Brief settle period for monitors
sleep 2

# --- Capture PowerTOP at start ---
echo "[2/5] Capturing initial PowerTOP report..."
POWERTOP_START="$LOGS_POWERTOP/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}_start.csv"
powertop --csv="$POWERTOP_START" --time=3 > /dev/null 2>&1 || true

# --- Run the topology workload ---
echo "[3/5] Running topology workload ($RUNS runs)..."
python3 "$TOPOLOGY_SCRIPT" \
    --workload "$WORKLOAD" \
    --size "$SIZE" \
    --runs "$RUNS" \
    --session-id "$SESSION_ID"

WORKLOAD_EXIT=$?
TIMESTAMP_END=$(date -Iseconds)

# --- Stop energy monitors ---
echo "[4/5] Stopping energy monitors..."
kill "$SCAPHANDRE_PID" 2>/dev/null || true
kill "$POWERSTAT_PID" 2>/dev/null || true
wait "$SCAPHANDRE_PID" 2>/dev/null || true
wait "$POWERSTAT_PID" 2>/dev/null || true
echo "  Monitors stopped."

# --- Capture final PowerTOP report ---
POWERTOP_END="$LOGS_POWERTOP/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}_end.csv"
powertop --csv="$POWERTOP_END" --time=3 > /dev/null 2>&1 || true

if [[ "$WORKLOAD_EXIT" -ne 0 ]]; then
    echo "ERROR: Topology workload exited with code $WORKLOAD_EXIT"
    exit 1
fi

# --- Parse and insert results ---
echo "[5/5] Parsing results and inserting into database..."

# Parse energy data
TOTAL_DURATION_S=$(python3 -c "
from datetime import datetime
start = datetime.fromisoformat('$TIMESTAMP_START')
end = datetime.fromisoformat('$TIMESTAMP_END')
print((end - start).total_seconds())
")

# Parse Scaphandre
SCAPH_JSON=$(python3 "$UTILS_DIR/parse_scaphandre.py" "$SCAPHANDRE_LOG" --json-output 2>/dev/null || echo '{"total_joules": 0, "avg_watts": 0}')
SCAPH_JOULES=$(echo "$SCAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

# Parse PowerStat
PSTAT_JSON=$(python3 "$UTILS_DIR/parse_powerstat.py" "$POWERSTAT_LOG" --duration "$TOTAL_DURATION_S" --json-output 2>/dev/null || echo '{"total_joules": 0, "avg_watts": 0}')
PSTAT_JOULES=$(echo "$PSTAT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

# Process the JSONL results and insert each run into the database
JSONL_FILE="$LOGS_IPERF3/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}.jsonl"

if [[ ! -f "$JSONL_FILE" ]]; then
    echo "ERROR: No JSONL output file found at $JSONL_FILE"
    exit 1
fi

# Calculate per-run energy allocation
ACTUAL_RUNS=$(wc -l < "$JSONL_FILE")
if [[ "$ACTUAL_RUNS" -gt 0 ]]; then
    SCAPH_PER_RUN=$(python3 -c "print($SCAPH_JOULES / $ACTUAL_RUNS)")
    PSTAT_PER_RUN=$(python3 -c "print($PSTAT_JOULES / $ACTUAL_RUNS)")
else
    SCAPH_PER_RUN=0
    PSTAT_PER_RUN=0
fi

# Insert runs into database
python3 << PYEOF
import json
import sqlite3

db = sqlite3.connect("$DB_PATH")
cur = db.cursor()

scaph_per_run = $SCAPH_PER_RUN
pstat_per_run = $PSTAT_PER_RUN

with open("$JSONL_FILE") as f:
    for line in f:
        r = json.loads(line.strip())
        if "error" in r:
            continue
        cur.execute("""
            INSERT INTO edge_runs (
                session_id, workload_type, workload_size_mb, run_number,
                timestamp_start, timestamp_end, duration_seconds,
                data_sent_mb, scaphandre_joules, powerstat_joules,
                cpu_peak_percent, cpu_avg_percent, powertop_flag, notes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            r.get("session_id", "$SESSION_ID"),
            r.get("workload_type", "$WORKLOAD"),
            r.get("workload_size_mb", 0),
            r.get("run_number", 0),
            r.get("timestamp_start", ""),
            r.get("timestamp_end", ""),
            r.get("duration_seconds", 0),
            r.get("data_sent_mb", 0),
            scaph_per_run,
            pstat_per_run,
            r.get("cpu_percent", 0),
            r.get("cpu_percent", 0),
            "baseline_start_end",
            None,
        ))

db.commit()
inserted = cur.execute("SELECT COUNT(*) FROM edge_runs WHERE session_id=?", ("$SESSION_ID",)).fetchone()[0]
print(f"Inserted {inserted} runs into edge_runs table")
db.close()
PYEOF

# --- Export to CSV ---
CSV_FILE="$EXPORTS_DIR/${SESSION_ID}_edge.csv"
sqlite3 -header -csv "$DB_PATH" \
    "SELECT * FROM edge_runs WHERE session_id='$SESSION_ID';" > "$CSV_FILE"
echo "Exported to: $CSV_FILE"

# --- Print summary ---
echo ""
echo "============================================"
echo "  WORKLOAD RUN COMPLETE"
echo "============================================"
echo "  Session:          $SESSION_ID"
echo "  Workload:         $WORKLOAD ($SIZE)"
echo "  Runs completed:   $ACTUAL_RUNS / $RUNS"
echo "  Total duration:   ${TOTAL_DURATION_S}s"
echo "  Scaphandre total: ${SCAPH_JOULES} J"
echo "  PowerStat total:  ${PSTAT_JOULES} J"
echo "  Per-run energy:   ~${SCAPH_PER_RUN} J (Scaphandre)"
echo "  Per-run energy:   ~${PSTAT_PER_RUN} J (PowerStat)"
echo "  JSONL:            $JSONL_FILE"
echo "  CSV:              $CSV_FILE"
echo "============================================"
