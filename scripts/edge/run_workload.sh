#!/bin/bash
# =============================================================================
# run_workload.sh — Run Edge Workloads with Energy Monitoring
# =============================================================================
# Server-side energy (Scaphandre, PowerStat) runs on Machine A.
# Client-side energy is measured on Machine B via SSH using client_daemon.sh.
#
# Traffic flow (post-fix):
#   - Machine A runs Containernet topology in server_only mode
#     (server container + switch; no dept containers)
#   - Machine B sends iperf3/HTTP traffic to Machine A's edge server over LAN
#     (192.168.1.x) — IDENTICAL pattern to cloud runs pointing at GCP
#   - Machine B measures its own energy during active transmission
#   Result: symmetric client energy measurement (edge vs cloud)
#
# Usage:
#   sudo bash run_workload.sh --session-id <id> --workload <type> \
#        --size <small|medium|large> --runs <N>
# =============================================================================

set -euo pipefail

# --- Project paths (absolute) ---
PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
DB_PATH="$PROJECT_DIR/data/results.db"
LOGS_POWERSTAT="$PROJECT_DIR/logs/powerstat"
LOGS_SCAPHANDRE="$PROJECT_DIR/logs/scaphandre"
LOGS_POWERTOP="$PROJECT_DIR/logs/powertop"
LOGS_IPERF3="$PROJECT_DIR/logs/iperf3"
EXPORTS_DIR="$PROJECT_DIR/exports"
UTILS_DIR="$PROJECT_DIR/scripts/utils"
TOPOLOGY_DIR="$PROJECT_DIR/topology"
TMP_DIR="$PROJECT_DIR/tmp"
STATE_FILE="$TMP_DIR/topology_state.json"
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
mkdir -p "$LOGS_POWERSTAT" "$LOGS_SCAPHANDRE" "$LOGS_POWERTOP" "$LOGS_IPERF3" "$EXPORTS_DIR" "$TMP_DIR"

# --- Check baseline exists ---
BASELINE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM edge_baselines WHERE session_id='$SESSION_ID';")
if [[ "$BASELINE_COUNT" -eq 0 ]]; then
    echo "WARNING: No baseline captured for session $SESSION_ID"
    echo "Consider running capture_baseline.sh first."
    echo "Continuing anyway..."
fi

declare -A FILE_SIZES
FILE_SIZES[small]=10485760     # 10 MB
FILE_SIZES[medium]=104857600   # 100 MB
FILE_SIZES[large]=524288000    # 500 MB

SIZE_SUFFIX=""
if [[ "$WORKLOAD" == "file_transfer" ]]; then
    SIZE_SUFFIX="_${SIZE}"
fi

JSONL_FILE="$LOGS_IPERF3/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}.jsonl"

TIMESTAMP_START=$(date -Iseconds)
echo "============================================"
echo "  Edge Workload Run (Machine B as client)"
echo "============================================"
echo "  Session:    $SESSION_ID"
echo "  Workload:   $WORKLOAD"
echo "  Size:       $SIZE"
echo "  Runs:       $RUNS"
echo "  Started:    $TIMESTAMP_START"
echo "  Client:     ${CLIENT_USER}@${CLIENT_IP} (Machine B)"
echo "============================================"

# --- [0] Start client measurement on Machine B ---
echo "[0/7] Starting client measurement on Machine B..."
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
echo "[1/7] Starting server-side energy monitors (Machine A)..."

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
echo "[2/7] Capturing initial PowerTOP report..."
POWERTOP_START="$LOGS_POWERTOP/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}_start.csv"
powertop --csv="$POWERTOP_START" --time=3 > /dev/null 2>&1 || true

# --- [3] Start edge server topology (server_only mode) ---
echo "[3/7] Starting edge server topology (server_only mode)..."
START_OUTPUT=$(bash "$TOPOLOGY_DIR/start_edge_server.sh" \
    --session-id "$SESSION_ID" --workload "$WORKLOAD" 2>&1)
echo "$START_OUTPUT"

if ! echo "$START_OUTPUT" | grep -q "EDGE_SERVER_READY"; then
    echo "ERROR: Edge server did not start correctly"
    kill "$SCAPHANDRE_PID" 2>/dev/null || true
    kill "$POWERSTAT_PID"  2>/dev/null || true
    $SSH_CLIENT "bash ~/edge_cloud_study/client_daemon.sh stop" > /dev/null 2>&1 || true
    exit 1
fi

EDGE_SERVER_IP=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['server_ip'])")
echo "  Edge server IP: $EDGE_SERVER_IP"

# --- [4] Run workload iterations — traffic FROM Machine B ---
echo "[4/7] Running $RUNS edge workload iterations (traffic from Machine B)..."

> "$JSONL_FILE"

for run_num in $(seq 1 "$RUNS"); do
    TIMESTAMP_RUN_START=$(date -Iseconds)
    START_MS=$(date +%s%N | cut -b1-13)

    if [[ "$WORKLOAD" == "file_transfer" ]]; then
        SIZE_BYTES=${FILE_SIZES[$SIZE]}
        # iperf3 client runs FROM Machine B to edge server on Machine A.
        # Redirect stdout to a local temp file — avoids bash quoting issues
        # and any "iperf Done." trailing line that would break json.loads().
        IPERF3_TMP="/tmp/iperf3_edge_${SESSION_ID}_${run_num}.json"
        $SSH_CLIENT "iperf3 -c $EDGE_SERVER_IP -n $SIZE_BYTES -J 2>/dev/null" \
            > "$IPERF3_TMP" || echo '{}' > "$IPERF3_TMP"
        END_MS=$(date +%s%N | cut -b1-13)
        TIMESTAMP_RUN_END=$(date -Iseconds)

        python3 << PYEOF >> "$JSONL_FILE"
import json
try:
    with open("$IPERF3_TMP") as f:
        content = f.read().strip()
    # raw_decode tolerates trailing text (e.g. "iperf Done.") after JSON
    decoder = json.JSONDecoder()
    data, _ = decoder.raw_decode(content)
    sent       = data.get("end", {}).get("sum_sent", {})
    duration   = sent.get("seconds", 0)
    bytes_sent = sent.get("bytes", 0)
    bps        = sent.get("bits_per_second", 0)
    cpu        = data.get("end", {}).get("cpu_utilization_percent", {}).get("host_total", 0)
    entry = {
        "run_number":       $run_num,
        "session_id":       "$SESSION_ID",
        "workload_type":    "file_transfer",
        "workload_size_mb": $SIZE_BYTES / (1024*1024),
        "timestamp_start":  "$TIMESTAMP_RUN_START",
        "timestamp_end":    "$TIMESTAMP_RUN_END",
        "duration_seconds": duration,
        "data_sent_mb":     bytes_sent / (1024*1024),
        "bits_per_second":  bps,
        "response_time_ms": ($END_MS - $START_MS),
        "cpu_percent":      cpu,
    }
except Exception as e:
    entry = {
        "run_number":      $run_num,
        "session_id":      "$SESSION_ID",
        "workload_type":   "file_transfer",
        "error":           "parse_failed: " + str(e),
        "timestamp_start": "$TIMESTAMP_RUN_START",
        "timestamp_end":   "$TIMESTAMP_RUN_END",
    }
print(json.dumps(entry))
PYEOF
        rm -f "$IPERF3_TMP"

    elif [[ "$WORKLOAD" == "web_request" ]]; then
        # HTTP requests originate FROM Machine B to edge server on Machine A
        RESULT=$($SSH_CLIENT python3 << PYEOF
import urllib.request, json, time
start       = time.time()
total_bytes = 0
times       = []
for i in range(50):
    t0 = time.time()
    try:
        resp = urllib.request.urlopen('http://${EDGE_SERVER_IP}:8080/', timeout=10)
        data = resp.read()
        total_bytes += len(data)
        times.append((time.time() - t0) * 1000)
    except:
        pass
elapsed = time.time() - start
avg_ms  = sum(times)/len(times) if times else 0
print(json.dumps({
    'run_number':       $run_num,
    'session_id':       '${SESSION_ID}',
    'workload_type':    'web_request',
    'workload_size_mb': total_bytes / (1024*1024),
    'timestamp_start':  '${TIMESTAMP_RUN_START}',
    'timestamp_end':    '${TIMESTAMP_RUN_START}',
    'duration_seconds': elapsed,
    'data_sent_mb':     total_bytes / (1024*1024),
    'response_time_ms': avg_ms,
    'cpu_percent':      0,
    'request_count':    50,
}))
PYEOF
)
        END_MS=$(date +%s%N | cut -b1-13)
        TIMESTAMP_RUN_END=$(date -Iseconds)
        # Fix the timestamp_end in the result
        RESULT=$(echo "$RESULT" | python3 -c "
import json, sys
r = json.load(sys.stdin)
r['timestamp_end'] = '$TIMESTAMP_RUN_END'
print(json.dumps(r))")
        echo "$RESULT" >> "$JSONL_FILE"

    elif [[ "$WORKLOAD" == "video_encoding" ]]; then
        # Encoding runs ON the server container via docker exec from Machine A.
        # Machine B measures its energy during the wait period.
        docker exec mn.server bash -c \
            "ffmpeg -y -f lavfi -i testsrc=duration=10:size=1280x720:rate=30 /tmp/test_input.mp4 2>/dev/null && \
             ffmpeg -y -i /tmp/test_input.mp4 -c:v libx264 -preset slow /tmp/output.mp4 2>/dev/null" \
            2>/dev/null || true
        END_MS=$(date +%s%N | cut -b1-13)
        TIMESTAMP_RUN_END=$(date -Iseconds)

        DURATION=$(python3 -c "
from datetime import datetime
start = datetime.fromisoformat('$TIMESTAMP_RUN_START')
end   = datetime.fromisoformat('$TIMESTAMP_RUN_END')
print((end - start).total_seconds())")

        python3 -c "
import json
print(json.dumps({
    'run_number':       $run_num,
    'session_id':       '$SESSION_ID',
    'workload_type':    'video_encoding',
    'workload_size_mb': 50.0,
    'timestamp_start':  '$TIMESTAMP_RUN_START',
    'timestamp_end':    '$TIMESTAMP_RUN_END',
    'duration_seconds': $DURATION,
    'data_sent_mb':     0,
    'response_time_ms': $DURATION * 1000,
    'cpu_percent':      0,
    'notes':            'compute_on_edge_server_machine_b_measures_wait',
}))" >> "$JSONL_FILE"

    elif [[ "$WORKLOAD" == "db_query" ]]; then
        # DB queries run ON the server container via docker exec from Machine A.
        # Machine B measures its energy during the wait period.
        docker exec mn.server python3 -c "
import sqlite3, random, string
conn = sqlite3.connect('/tmp/test_students.db')
c = conn.cursor()
c.execute('CREATE TABLE IF NOT EXISTS students (id INT, name TEXT, dept TEXT, gpa REAL, year INT)')
if c.execute('SELECT COUNT(*) FROM students').fetchone()[0] < 100000:
    data = [(i,''.join(random.choices(string.ascii_letters,k=10)),
              random.choice(['CS','EE','ME','CE','BIO']),
              round(random.uniform(2.0,4.0),2),random.randint(1,4))
             for i in range(100000)]
    c.executemany('INSERT INTO students VALUES (?,?,?,?,?)', data)
    conn.commit()
for _ in range(100):
    c.execute(\"\"\"SELECT s.name,s.dept,s.gpa FROM students s
                  WHERE s.dept='CS' AND s.gpa>3.5 AND s.year>=3
                  ORDER BY s.gpa DESC LIMIT 50\"\"\")
    c.fetchall()
conn.close()
" 2>/dev/null || true
        END_MS=$(date +%s%N | cut -b1-13)
        TIMESTAMP_RUN_END=$(date -Iseconds)

        DURATION=$(python3 -c "
from datetime import datetime
start = datetime.fromisoformat('$TIMESTAMP_RUN_START')
end   = datetime.fromisoformat('$TIMESTAMP_RUN_END')
print((end - start).total_seconds())")

        python3 -c "
import json
print(json.dumps({
    'run_number':       $run_num,
    'session_id':       '$SESSION_ID',
    'workload_type':    'db_query',
    'workload_size_mb': 5.0,
    'timestamp_start':  '$TIMESTAMP_RUN_START',
    'timestamp_end':    '$TIMESTAMP_RUN_END',
    'duration_seconds': $DURATION,
    'data_sent_mb':     0,
    'response_time_ms': $DURATION * 1000,
    'cpu_percent':      0,
    'request_count':    100,
    'notes':            'compute_on_edge_server_machine_b_measures_wait',
}))" >> "$JSONL_FILE"
    fi

    echo "  Run $run_num/$RUNS done"
done

TIMESTAMP_END=$(date -Iseconds)

# --- [5] Stop edge server ---
echo "[5/7] Stopping edge server topology..."
bash "$TOPOLOGY_DIR/stop_edge_server.sh"

# --- [6] Stop server-side energy monitors ---
echo "[6/7] Stopping server-side energy monitors..."
kill "$SCAPHANDRE_PID" 2>/dev/null || true
kill "$POWERSTAT_PID"  2>/dev/null || true
wait "$SCAPHANDRE_PID" 2>/dev/null || true
wait "$POWERSTAT_PID"  2>/dev/null || true
echo "  Server monitors stopped."

# Capture final PowerTOP
POWERTOP_END="$LOGS_POWERTOP/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}_end.csv"
powertop --csv="$POWERTOP_END" --time=3 > /dev/null 2>&1 || true

# --- [6.5] Stop client measurement on Machine B ---
echo "[6.5/7] Stopping client measurement on Machine B..."
CLIENT_TMP="/tmp/client_summary_${SESSION_ID}.json"
$SSH_CLIENT "bash ~/edge_cloud_study/client_daemon.sh stop" > "$CLIENT_TMP"
echo "  Machine B measurement stopped."

# Verify we got a valid JSON summary
if ! python3 -c "import json; json.load(open('$CLIENT_TMP'))" 2>/dev/null; then
    echo "WARNING: Client summary from Machine B is not valid JSON:"
    cat "$CLIENT_TMP" >&2
    echo '{"scaphandre_joules":0,"powerstat_joules":0,"cpu_peak_percent":0,"cpu_avg_percent":0,"duration_seconds":0,"start_time":"","stop_time":""}' > "$CLIENT_TMP"
fi

# --- [7] Parse server-side results and insert into database ---
echo "[7/7] Parsing results and inserting into database..."

TOTAL_DURATION_S=$(python3 -c "
from datetime import datetime
start = datetime.fromisoformat('$TIMESTAMP_START')
end   = datetime.fromisoformat('$TIMESTAMP_END')
print((end - start).total_seconds())
")

if [[ ! -f "$JSONL_FILE" ]]; then
    echo "ERROR: No JSONL output file found at $JSONL_FILE"
    exit 1
fi

ACTUAL_RUNS=$(wc -l < "$JSONL_FILE")

# Parse server-side Scaphandre
SCAPH_JSON=$(python3 "$UTILS_DIR/parse_scaphandre.py" "$SCAPHANDRE_LOG" --json-output \
             2>/dev/null || echo '{"total_joules": 0, "avg_watts": 0}')
SCAPH_JOULES=$(echo "$SCAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

# Parse server-side PowerStat
PSTAT_JSON=$(python3 "$UTILS_DIR/parse_powerstat.py" "$POWERSTAT_LOG" \
             --duration "$TOTAL_DURATION_S" --json-output \
             2>/dev/null || echo '{"total_joules": 0, "avg_watts": 0}')
PSTAT_JOULES=$(echo "$PSTAT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_joules', 0))")

if [[ "$ACTUAL_RUNS" -gt 0 ]]; then
    SCAPH_PER_RUN=$(python3 -c "print($SCAPH_JOULES / $ACTUAL_RUNS)")
    PSTAT_PER_RUN=$(python3 -c "print($PSTAT_JOULES / $ACTUAL_RUNS)")
else
    SCAPH_PER_RUN=0
    PSTAT_PER_RUN=0
fi

# Insert edge_runs rows (one row per JSONL entry)
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
            r.get("notes", None),
        ))

db.commit()
inserted = cur.execute(
    "SELECT COUNT(*) FROM edge_runs WHERE session_id=?", ("$SESSION_ID",)
).fetchone()[0]
print(f"Inserted {inserted} runs into edge_runs table")
db.close()
PYEOF

# Calculate average response_time_ms across all runs (for client_energy_runs)
AVG_RESPONSE_MS=$(python3 -c "
import json
times = []
with open('$JSONL_FILE') as f:
    for line in f:
        r = json.loads(line.strip())
        if 'error' not in r and r.get('response_time_ms', 0) > 0:
            times.append(r['response_time_ms'])
print(sum(times)/len(times) if times else 0)
")

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
    ) VALUES (?, 'edge', ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    $AVG_RESPONSE_MS,
    "machine_b_over_lan_to_edge_server",
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

# --- Export to CSV ---
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
echo "  Client Edge Energy (Machine B — LAN transmission):"
echo "    Scaphandre total: ${CLIENT_SCAPH_J} J"
echo "    PowerStat total:  ${CLIENT_PSTAT_J} J"
echo "    Avg response_ms:  ${AVG_RESPONSE_MS}"
echo "  JSONL:            $JSONL_FILE"
echo "  Server CSV:       $CSV_FILE"
echo "  Client CSV:       $CLIENT_CSV_FILE"
echo "============================================"
