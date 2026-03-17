#!/bin/bash
# =============================================================================
# run_workload.sh — Run Edge Workloads with Energy Monitoring
# =============================================================================
# Server-side energy (Scaphandre, PowerStat) runs on Machine A as before.
# Client-side energy is measured independently on Machine B via SSH
# using client_daemon.sh — eliminating the same-machine measurement bias.
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

# --- Read Machine B config ---
CLIENT_IP=$(python3   -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_ip'])")
CLIENT_USER=$(python3 -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_user'])")
SSH_KEY=$(python3     -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_ssh_key'])")
SSH_CLIENT="ssh -o StrictHostKeyChecking=no -i $SSH_KEY ${CLIENT_USER}@${CLIENT_IP}"

# --- Parse arguments ---
SESSION_ID=""
WORKLOAD=""
SIZE="small"
RUNS=1000

while [[ $# -gt 0 ]]; do
    case $1 in
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --workload)   WORKLOAD="$2";   shift 2 ;;
        --size)       SIZE="$2";       shift 2 ;;
        --runs)       RUNS="$2";       shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SESSION_ID" || -z "$WORKLOAD" ]]; then
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
echo "  Client:     ${CLIENT_USER}@${CLIENT_IP}"
echo "============================================"

# --- [0] Start client measurement on Machine B ---
echo "[0/6] Starting client measurement on Machine B..."
$SSH_CLIENT \
    "bash ~/edge_cloud_study/client_daemon.sh start \
     --session-id $SESSION_ID --environment edge \
     --workload $WORKLOAD --size $SIZE --run-number $RUNS" \
    | grep -v "^$" || true

# Verify Machine B measurement is running
READY=$($SSH_CLIENT \
    "python3 -c \"import json,os; print(json.load(open(os.path.expanduser('~/edge_cloud_study/tmp/measurement_state.json')))['status'])\"" \
    2>/dev/null || echo "unknown")

if [[ "$READY" != "running" ]]; then
    echo "ERROR: Client measurement did not start on Machine B (status: $READY)"
    exit 1
fi
echo "  Machine B client measurement running."

# --- [1] Start background energy monitors (server-side on Machine A) ---
echo "[1/6] Starting server-side energy monitors (Machine A)..."

SCAPHANDRE_LOG="$LOGS_SCAPHANDRE/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}.json"
scaphandre json -s 1 -f "$SCAPHANDRE_LOG" > /dev/null 2>&1 &
SCAPHANDRE_PID=$!
echo "  Scaphandre started (PID: $SCAPHANDRE_PID)"

POWERSTAT_LOG="$LOGS_POWERSTAT/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}.log"
powerstat -R -z -d 0 1 3600 > "$POWERSTAT_LOG" 2>&1 &
POWERSTAT_PID=$!
echo "  PowerStat started (PID: $POWERSTAT_PID)"

sleep 2

# --- [2] Capture PowerTOP at start ---
echo "[2/6] Capturing initial PowerTOP report..."
POWERTOP_START="$LOGS_POWERTOP/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}_start.csv"
powertop --csv="$POWERTOP_START" --time=3 > /dev/null 2>&1 || true

# --- [3] Run the topology workload ---
echo "[3/6] Running topology workload ($RUNS runs)..."
python3 "$TOPOLOGY_SCRIPT" \
    --workload "$WORKLOAD" \
    --size "$SIZE" \
    --runs "$RUNS" \
    --session-id "$SESSION_ID"

WORKLOAD_EXIT=$?
TIMESTAMP_END=$(date -Iseconds)

# --- [4] Stop server-side energy monitors ---
echo "[4/6] Stopping server-side energy monitors..."
kill "$SCAPHANDRE_PID" 2>/dev/null || true
kill "$POWERSTAT_PID"  2>/dev/null || true
wait "$SCAPHANDRE_PID" 2>/dev/null || true
wait "$POWERSTAT_PID"  2>/dev/null || true
echo "  Server monitors stopped."

# Capture final PowerTOP
POWERTOP_END="$LOGS_POWERTOP/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}_end.csv"
powertop --csv="$POWERTOP_END" --time=3 > /dev/null 2>&1 || true

if [[ "$WORKLOAD_EXIT" -ne 0 ]]; then
    # Stop Machine B even on failure
    $SSH_CLIENT "bash ~/edge_cloud_study/client_daemon.sh stop" > /dev/null 2>&1 || true
    echo "ERROR: Topology workload exited with code $WORKLOAD_EXIT"
    exit 1
fi

# --- [4.5] Stop client measurement on Machine B ---
echo "[4.5/6] Stopping client measurement on Machine B..."
CLIENT_TMP="/tmp/client_summary_${SESSION_ID}.json"
$SSH_CLIENT "bash ~/edge_cloud_study/client_daemon.sh stop" > "$CLIENT_TMP"
echo "  Machine B measurement stopped."

# Verify we got a valid JSON summary
if ! python3 -c "import json; json.load(open('$CLIENT_TMP'))" 2>/dev/null; then
    echo "WARNING: Client summary from Machine B is not valid JSON:"
    cat "$CLIENT_TMP" >&2
    echo '{"scaphandre_joules":0,"powerstat_joules":0,"cpu_peak_percent":0,"cpu_avg_percent":0,"duration_seconds":0,"start_time":"","stop_time":""}' > "$CLIENT_TMP"
fi

# --- [5] Parse server-side results and insert into database ---
echo "[5/6] Parsing results and inserting into database..."

TOTAL_DURATION_S=$(python3 -c "
from datetime import datetime
start = datetime.fromisoformat('$TIMESTAMP_START')
end   = datetime.fromisoformat('$TIMESTAMP_END')
print((end - start).total_seconds())
")

# Parse server-side Scaphandre
SCAPH_JSON=$(python3 "$UTILS_DIR/parse_scaphandre.py" "$SCAPHANDRE_LOG" --json-output \
             2>/dev/null || echo '{"total_joules": 0, "avg_watts": 0}')
SCAPH_JOULES=$(echo "$SCAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

# Parse server-side PowerStat
PSTAT_JSON=$(python3 "$UTILS_DIR/parse_powerstat.py" "$POWERSTAT_LOG" \
             --duration "$TOTAL_DURATION_S" --json-output \
             2>/dev/null || echo '{"total_joules": 0, "avg_watts": 0}')
PSTAT_JOULES=$(echo "$PSTAT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

# Process JSONL and insert edge_runs rows
JSONL_FILE="$LOGS_IPERF3/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}.jsonl"

if [[ ! -f "$JSONL_FILE" ]]; then
    echo "ERROR: No JSONL output file found at $JSONL_FILE"
    exit 1
fi

ACTUAL_RUNS=$(wc -l < "$JSONL_FILE")
if [[ "$ACTUAL_RUNS" -gt 0 ]]; then
    SCAPH_PER_RUN=$(python3 -c "print($SCAPH_JOULES / $ACTUAL_RUNS)")
    PSTAT_PER_RUN=$(python3 -c "print($PSTAT_JOULES / $ACTUAL_RUNS)")
else
    SCAPH_PER_RUN=0
    PSTAT_PER_RUN=0
fi

# Insert edge_runs rows
python3 << PYEOF
import json, sqlite3

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
inserted = cur.execute(
    "SELECT COUNT(*) FROM edge_runs WHERE session_id=?", ("$SESSION_ID",)
).fetchone()[0]
print(f"Inserted {inserted} runs into edge_runs table")
db.close()
PYEOF

# Insert client_energy_runs from Machine B JSON summary
python3 << PYEOF
import json, sqlite3

db = sqlite3.connect("$DB_PATH")
cur = db.cursor()

with open("$CLIENT_TMP") as f:
    client_data = json.load(f)

# Get total data_sent from edge_runs for this session
res = cur.execute(
    "SELECT SUM(data_sent_mb) FROM edge_runs WHERE session_id=?", ("$SESSION_ID",)
).fetchone()
data_sent = res[0] if res and res[0] is not None else 0.0

cur.execute("""
    INSERT INTO client_energy_runs (
        session_id, environment, workload_type, workload_size_mb, run_number,
        timestamp_start, timestamp_end, duration_seconds, data_sent_mb,
        client_scaphandre_joules, client_powerstat_joules,
        client_cpu_peak_percent, client_cpu_avg_percent,
        response_time_ms, notes
    ) VALUES (?, 'edge', ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
""", (
    "$SESSION_ID",
    "$WORKLOAD",
    $RUNS,
    client_data.get("start_time", "$TIMESTAMP_START"),
    client_data.get("stop_time",  "$TIMESTAMP_END"),
    client_data.get("duration_seconds",  0.0),
    data_sent,
    client_data.get("scaphandre_joules", 0.0),
    client_data.get("powerstat_joules",  0.0),
    client_data.get("cpu_peak_percent",  0.0),
    client_data.get("cpu_avg_percent",   0.0),
    "machine_b_independent_measurement",
))
db.commit()
print("Inserted client_energy_runs row from Machine B measurement.")
db.close()
PYEOF

rm -f "$CLIENT_TMP"

# Extract client values for summary output
CLIENT_SCAPH_J=$(sqlite3 "$DB_PATH" \
    "SELECT client_scaphandre_joules FROM client_energy_runs \
     WHERE session_id='$SESSION_ID' AND environment='edge' \
     ORDER BY run_id DESC LIMIT 1;")
CLIENT_PSTAT_J=$(sqlite3 "$DB_PATH" \
    "SELECT client_powerstat_joules FROM client_energy_runs \
     WHERE session_id='$SESSION_ID' AND environment='edge' \
     ORDER BY run_id DESC LIMIT 1;")

# --- [6] Export to CSV ---
echo "[6/6] Exporting CSVs..."
CSV_FILE="$EXPORTS_DIR/${SESSION_ID}_edge.csv"
sqlite3 -header -csv "$DB_PATH" \
    "SELECT * FROM edge_runs WHERE session_id='$SESSION_ID';" > "$CSV_FILE"
echo "Exported server edge data to: $CSV_FILE"

CLIENT_CSV_FILE="$EXPORTS_DIR/${SESSION_ID}_client_edge.csv"
sqlite3 -header -csv "$DB_PATH" \
    "SELECT * FROM client_energy_runs WHERE session_id='$SESSION_ID' AND environment='edge';" > "$CLIENT_CSV_FILE"
echo "Exported client edge data to: $CLIENT_CSV_FILE"

# --- Print summary ---
echo ""
echo "============================================"
echo "  WORKLOAD RUN COMPLETE"
echo "============================================"
echo "  Session:          $SESSION_ID"
echo "  Workload:         $WORKLOAD ($SIZE)"
echo "  Runs completed:   $ACTUAL_RUNS / $RUNS"
echo "  Total duration:   ${TOTAL_DURATION_S}s"
echo "  Server Edge Energy (Machine A):"
echo "    Scaphandre total: ${SCAPH_JOULES} J"
echo "    PowerStat total:  ${PSTAT_JOULES} J"
echo "    Per-run (~):      ${SCAPH_PER_RUN} J (Scaphandre)"
echo "    Per-run (~):      ${PSTAT_PER_RUN} J (PowerStat)"
echo "  Client Edge Energy (Machine B — independent):"
echo "    Scaphandre total: ${CLIENT_SCAPH_J} J"
echo "    PowerStat total:  ${CLIENT_PSTAT_J} J"
echo "  JSONL:            $JSONL_FILE"
echo "  Server CSV:       $CSV_FILE"
echo "  Client CSV:       $CLIENT_CSV_FILE"
echo "============================================"
