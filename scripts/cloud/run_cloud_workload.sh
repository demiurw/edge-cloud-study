#!/bin/bash
# =============================================================================
# run_cloud_workload.sh — Execute Workloads on GCP e2-micro
# =============================================================================
# Client traffic (iperf3, HTTP) originates FROM Machine B so that Machine B
# measures its own energy during actual network transmission — symmetric with
# edge runs. Machine A handles GCP monitoring, topology coordination, and DB.
#
# Usage:
#   bash run_cloud_workload.sh --session-id <id> --workload <type> \
#        --size <size> --runs <N> --instance-ip <ip> --project-id <pid> \
#        --instance-id <instance>
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
DB_PATH="$PROJECT_DIR/data/results.db"
LOGS_CLOUD="$PROJECT_DIR/logs/cloud"
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
INSTANCE_IP=""
PROJECT_ID=""
INSTANCE_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --session-id)   SESSION_ID="$2";   shift 2 ;;
        --workload)     WORKLOAD="$2";     shift 2 ;;
        --size)         SIZE="$2";         shift 2 ;;
        --runs)         RUNS="$2";         shift 2 ;;
        --instance-ip)  INSTANCE_IP="$2";  shift 2 ;;
        --project-id)   PROJECT_ID="$2";   shift 2 ;;
        --instance-id)  INSTANCE_ID="$2";  shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SESSION_ID" || -z "$WORKLOAD" || -z "$INSTANCE_IP" || \
      -z "$PROJECT_ID" || -z "$INSTANCE_ID" ]]; then
    echo "ERROR: --session-id, --workload, --instance-ip, --project-id, --instance-id required"
    exit 1
fi

ZONE="us-central1-a"
mkdir -p "$LOGS_CLOUD" "$EXPORTS_DIR"

declare -A FILE_SIZES
FILE_SIZES[small]=10485760     # 10 MB
FILE_SIZES[medium]=104857600   # 100 MB
FILE_SIZES[large]=524288000    # 500 MB

SIZE_SUFFIX=""
[[ "$WORKLOAD" == "file_transfer" ]] && SIZE_SUFFIX="_${SIZE}"

CLOUD_LOG="$LOGS_CLOUD/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}.jsonl"
GCP_LOG="$LOGS_CLOUD/${SESSION_ID}_${WORKLOAD}${SIZE_SUFFIX}_gcp_raw.jsonl"

echo "============================================"
echo "  Cloud Workload Run (GCP)"
echo "============================================"
echo "  Session:     $SESSION_ID"
echo "  Workload:    $WORKLOAD"
echo "  Size:        $SIZE"
echo "  Runs:        $RUNS"
echo "  Instance IP: $INSTANCE_IP"
echo "  Client:      ${CLIENT_USER}@${CLIENT_IP} (Machine B)"
echo "============================================"

# --- [0] Verify Machine B connectivity ---
echo "[0/4] Verifying Machine B connectivity..."
if ! $SSH_CLIENT "echo OK" | grep -q OK; then
    echo "ERROR: Machine B not reachable at $CLIENT_IP"
    exit 1
fi
echo "  Machine B OK."

# --- [1] Verify GCP iperf3 server ---
echo "[1/4] Verifying GCP instance iperf3 server..."
ssh -o StrictHostKeyChecking=no "ubuntu@$INSTANCE_IP" \
    "pkill iperf3 2>/dev/null; iperf3 -s -D" 2>/dev/null || true

# --- [2] Start client measurement on Machine B ---
echo "[2/4] Starting client energy measurement on Machine B..."
$SSH_CLIENT \
    "bash ~/edge_cloud_study/client_daemon.sh start \
     --session-id $SESSION_ID --environment cloud \
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

> "$CLOUD_LOG"
> "$GCP_LOG"

# --- Start background GCP metric polling (Machine A polls GCP API) ---
METRIC_TMP="/tmp/gcp_metrics_${SESSION_ID}.txt"
> "$METRIC_TMP"

python3 << 'EOF' > "$METRIC_TMP" &
from google.cloud import monitoring_v3
import time, json, sys, os

project_id  = os.environ.get("PROJECT_ID", "")
instance_id = os.environ.get("INSTANCE_ID", "")
gcp_log     = os.environ.get("GCP_LOG", "/dev/null")

if not project_id:
    sys.exit(0)

try:
    client       = monitoring_v3.MetricServiceClient()
    project_name = f"projects/{project_id}"
except Exception as e:
    with open(gcp_log, "a") as f:
        f.write(json.dumps({"error": str(e)}) + "\n")
    sys.exit(1)

cpu_filter = (
    f'metric.type="compute.googleapis.com/instance/cpu/utilization"'
    f' AND resource.labels.instance_id="{instance_id}"'
)

while True:
    now      = time.time()
    interval = monitoring_v3.TimeInterval()
    interval.end_time.seconds   = int(now)
    interval.start_time.seconds = int(now) - 60
    try:
        results = client.list_time_series(
            request={"name": project_name, "filter": cpu_filter,
                     "interval": interval,
                     "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL}
        )
        for result in results:
            for point in result.points:
                with open(gcp_log, "a") as f:
                    f.write(json.dumps({
                        "metric":    "cpu_utilization",
                        "value":     point.value.double_value,
                        "timestamp": point.interval.end_time.seconds,
                    }) + "\n")
    except Exception as e:
        with open(gcp_log, "a") as f:
            f.write(json.dumps({"error": str(e)}) + "\n")
    time.sleep(10)
EOF
POLL_PID=$!
export PROJECT_ID="$PROJECT_ID"
export INSTANCE_ID="$INSTANCE_ID"
export GCP_LOG="$GCP_LOG"

# --- [3] Run workloads — traffic originates FROM Machine B ---
echo "[3/4] Running $RUNS cloud workload iterations (traffic from Machine B)..."

for run_num in $(seq 1 "$RUNS"); do
    TIMESTAMP_START=$(date -Iseconds)
    START_MS=$(date +%s%N | cut -b1-13)

    if [[ "$WORKLOAD" == "file_transfer" ]]; then
        SIZE_BYTES=${FILE_SIZES[$SIZE]}
        # iperf3 client runs FROM Machine B to GCP instance.
        # Redirect to temp file — avoids bash quoting issues and trailing
        # "iperf Done." lines that break json.loads().
        IPERF3_TMP="/tmp/iperf3_cloud_${SESSION_ID}_${run_num}.json"
        $SSH_CLIENT "iperf3 -c $INSTANCE_IP -n $SIZE_BYTES -J 2>/dev/null" \
            > "$IPERF3_TMP" || echo '{}' > "$IPERF3_TMP"
        END_MS=$(date +%s%N | cut -b1-13)
        TIMESTAMP_END=$(date -Iseconds)

        python3 << PYEOF >> "$CLOUD_LOG"
import json
try:
    with open("$IPERF3_TMP") as f:
        content = f.read().strip()
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
        "timestamp_start":  "$TIMESTAMP_START",
        "timestamp_end":    "$TIMESTAMP_END",
        "duration_seconds": duration,
        "data_sent_mb":     bytes_sent / (1024*1024),
        "bandwidth_out_mb": bps / (8*1024*1024),
        "response_time_ms": ($END_MS - $START_MS),
        "cpu_avg_percent":  cpu,
        "request_count":    1,
    }
except Exception as e:
    entry = {
        "run_number":      $run_num,
        "session_id":      "$SESSION_ID",
        "workload_type":   "file_transfer",
        "error":           "parse_failed: " + str(e),
        "timestamp_start": "$TIMESTAMP_START",
        "timestamp_end":   "$TIMESTAMP_END",
    }
print(json.dumps(entry))
PYEOF
        rm -f "$IPERF3_TMP"

    elif [[ "$WORKLOAD" == "web_request" ]]; then
        # HTTP requests originate FROM Machine B to GCP
        RESULT=$($SSH_CLIENT python3 << PYEOF
import urllib.request, json, time
start       = time.time()
total_bytes = 0
times       = []
for i in range(50):
    t0 = time.time()
    try:
        resp = urllib.request.urlopen('http://${INSTANCE_IP}:8080/', timeout=10)
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
    'timestamp_start':  '${TIMESTAMP_START}',
    'timestamp_end':    '${TIMESTAMP_END}',
    'duration_seconds': elapsed,
    'data_sent_mb':     total_bytes / (1024*1024),
    'bandwidth_out_mb': (total_bytes/(1024*1024))/elapsed if elapsed > 0 else 0,
    'response_time_ms': avg_ms,
    'cpu_avg_percent':  0,
    'request_count':    50,
}))
PYEOF
)
        echo "$RESULT" >> "$CLOUD_LOG"

    else
        # video_encoding / db_query run on GCP server (SSH from Machine A).
        # Machine B measures its energy during the wait period.
        # Note: Machine B energy for these workloads reflects waiting/idle overhead,
        #       not active client computation. Recorded but interpreted accordingly.
        REMOTE_RESULT=$(ssh -o StrictHostKeyChecking=no "ubuntu@$INSTANCE_IP" \
            "python3 -c \"
import time, json
start = time.time()
if '$WORKLOAD' == 'video_encoding':
    import subprocess
    subprocess.run(['ffmpeg', '-y', '-f', 'lavfi', '-i',
                    'testsrc=duration=10:size=1280x720:rate=30', '/tmp/test.mp4'],
                   capture_output=True)
    subprocess.run(['ffmpeg', '-y', '-i', '/tmp/test.mp4', '-c:v', 'libx264',
                    '-preset', 'slow', '/tmp/out.mp4'], capture_output=True)
elif '$WORKLOAD' == 'db_query':
    import sqlite3, random, string
    conn = sqlite3.connect('/tmp/test.db')
    c = conn.cursor()
    c.execute('CREATE TABLE IF NOT EXISTS t (id INT, name TEXT, val REAL)')
    if c.execute('SELECT COUNT(*) FROM t').fetchone()[0] < 100000:
        c.executemany('INSERT INTO t VALUES (?,?,?)',
            [(i,''.join(random.choices(string.ascii_letters,k=8)),random.random())
             for i in range(100000)])
        conn.commit()
    for _ in range(100):
        c.execute('SELECT * FROM t WHERE val > 0.5 ORDER BY val LIMIT 50')
        c.fetchall()
    conn.close()
elapsed = time.time() - start
print(json.dumps({'duration': elapsed}))
\"" 2>/dev/null || echo '{"duration": 0}')

        DURATION=$(echo "$REMOTE_RESULT" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('duration',0))")
        TIMESTAMP_END=$(date -Iseconds)

        python3 -c "
import json
print(json.dumps({
    'run_number':       $run_num,
    'session_id':       '$SESSION_ID',
    'workload_type':    '$WORKLOAD',
    'workload_size_mb': 50 if '$WORKLOAD' == 'video_encoding' else 5,
    'timestamp_start':  '$TIMESTAMP_START',
    'timestamp_end':    '$TIMESTAMP_END',
    'duration_seconds': $DURATION,
    'data_sent_mb':     0,
    'bandwidth_out_mb': 0,
    'response_time_ms': $DURATION * 1000,
    'cpu_avg_percent':  0,
    'request_count':    100 if '$WORKLOAD' == 'db_query' else 1,
}))
" >> "$CLOUD_LOG"
    fi

    echo "  Run $run_num/$RUNS done"
done

kill -9 $POLL_PID 2>/dev/null || true

# --- [4] Stop client measurement on Machine B ---
echo "[4/4] Stopping client measurement on Machine B..."
CLIENT_TMP="/tmp/client_summary_${SESSION_ID}_cloud.json"
$SSH_CLIENT "bash ~/edge_cloud_study/client_daemon.sh stop" > "$CLIENT_TMP"
echo "  Machine B measurement stopped."

if ! python3 -c "import json; json.load(open('$CLIENT_TMP'))" 2>/dev/null; then
    echo "WARNING: Client summary from Machine B is not valid JSON:"
    cat "$CLIENT_TMP" >&2
    echo '{"scaphandre_joules":0,"powerstat_joules":0,"cpu_peak_percent":0,"cpu_avg_percent":0,"duration_seconds":0,"start_time":"","stop_time":""}' > "$CLIENT_TMP"
fi

# Extract client energy values for display
CLIENT_SCAPH_J=$(python3 -c "import json; print(json.load(open('$CLIENT_TMP')).get('scaphandre_joules', 0))")
CLIENT_PSTAT_J=$(python3 -c "import json; print(json.load(open('$CLIENT_TMP')).get('powerstat_joules', 0))")

# --- Insert into cloud_runs table ---
echo "Inserting cloud_runs into database..."
python3 << PYEOF
import json, sqlite3

db  = sqlite3.connect("$DB_PATH")
cur = db.cursor()

with open("$CLOUD_LOG") as f:
    for line in f:
        r = json.loads(line.strip())
        if "error" in r:
            continue
        cur.execute("""
            INSERT INTO cloud_runs (
                session_id, workload_type, workload_size_mb, run_number,
                timestamp_start, timestamp_end, duration_seconds,
                data_sent_mb, bandwidth_out_mb, response_time_ms,
                cpu_avg_percent, request_count, notes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            r.get("session_id"),      r.get("workload_type"),
            r.get("workload_size_mb", 0), r.get("run_number", 0),
            r.get("timestamp_start", ""), r.get("timestamp_end", ""),
            r.get("duration_seconds", 0), r.get("data_sent_mb", 0),
            r.get("bandwidth_out_mb", 0), r.get("response_time_ms", 0),
            r.get("cpu_avg_percent", 0),  r.get("request_count", 0),
            None,
        ))

db.commit()
count = cur.execute(
    "SELECT COUNT(*) FROM cloud_runs WHERE session_id=?", ("$SESSION_ID",)
).fetchone()[0]
print(f"Inserted {count} cloud runs into database")
db.close()
PYEOF

# Calculate average response_time_ms from cloud JSONL
AVG_RESPONSE_MS=$(python3 -c "
import json
times = []
with open('$CLOUD_LOG') as f:
    for line in f:
        r = json.loads(line.strip())
        if 'error' not in r and r.get('response_time_ms', 0) > 0:
            times.append(r['response_time_ms'])
print(sum(times)/len(times) if times else 0)
")

# --- Insert client_energy_runs from Machine B JSON summary ---
echo "Inserting client_energy_runs (Machine B) into database..."
python3 << PYEOF
import json, sqlite3

db  = sqlite3.connect("$DB_PATH")
cur = db.cursor()

with open("$CLIENT_TMP") as f:
    client_data = json.load(f)

res = cur.execute(
    "SELECT SUM(data_sent_mb) FROM cloud_runs WHERE session_id=?", ("$SESSION_ID",)
).fetchone()
data_sent = res[0] if res and res[0] is not None else 0.0

cur.execute("""
    INSERT INTO client_energy_runs (
        session_id, environment, workload_type, workload_size_mb, run_number,
        timestamp_start, timestamp_end, duration_seconds, data_sent_mb,
        client_scaphandre_joules, client_powerstat_joules,
        client_cpu_peak_percent, client_cpu_avg_percent,
        response_time_ms, notes
    ) VALUES (?, 'cloud', ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""", (
    "$SESSION_ID",
    "$WORKLOAD",
    $RUNS,
    client_data.get("start_time",        ""),
    client_data.get("stop_time",         ""),
    client_data.get("duration_seconds",  0.0),
    data_sent,
    client_data.get("scaphandre_joules", 0.0),
    client_data.get("powerstat_joules",  0.0),
    client_data.get("cpu_peak_percent",  0.0),
    client_data.get("cpu_avg_percent",   0.0),
    $AVG_RESPONSE_MS,
    "machine_b_over_wan_to_gcp_server",
))
db.commit()
print("Inserted client_energy_runs row from Machine B measurement.")
db.close()
PYEOF

rm -f "$CLIENT_TMP"

# --- Export CSVs ---
CSV_FILE="$EXPORTS_DIR/${SESSION_ID}_cloud.csv"
sqlite3 -header -csv "$DB_PATH" \
    "SELECT * FROM cloud_runs WHERE session_id='$SESSION_ID';" > "$CSV_FILE"
echo "Exported server cloud data to: $CSV_FILE"

CLIENT_CSV_FILE="$EXPORTS_DIR/${SESSION_ID}_client_cloud.csv"
sqlite3 -header -csv "$DB_PATH" \
    "SELECT * FROM client_energy_runs WHERE session_id='$SESSION_ID' AND environment='cloud';" > "$CLIENT_CSV_FILE"
echo "Exported client cloud data to: $CLIENT_CSV_FILE"

# --- Between-workload cleanup ---
echo "Performing between-workload cleanup..."
gcloud compute ssh edgecloud-server --zone="$ZONE" --project="$PROJECT_ID" \
    --command="pkill iperf3 2>/dev/null; sleep 2; nohup iperf3 -s -D >/dev/null 2>&1 &" \
    --quiet 2>/dev/null || true

if ! gcloud compute ssh edgecloud-server --zone="$ZONE" --project="$PROJECT_ID" \
        --command="echo OK" --quiet >/dev/null 2>&1; then
    echo "  WARNING: GCP instance health check failed. Verify instance state."
fi

BOUNDARIES_LOG="$LOGS_CLOUD/workload_boundaries.log"
TIMESTAMP_BOUNDARY=$(date -Iseconds)
echo "${SESSION_ID} | ${WORKLOAD} | completed | ${TIMESTAMP_BOUNDARY}" >> "$BOUNDARIES_LOG"

echo ""
echo "============================================"
echo "  CLOUD WORKLOAD COMPLETE (GCP)"
echo "============================================"
echo "  Runs:           $RUNS"
echo "  Log:            $CLOUD_LOG"
echo "  GCP Log:        $GCP_LOG"
echo "  Server CSV:     $CSV_FILE"
echo "  Client CSV:     $CLIENT_CSV_FILE"
echo "  Client machine: ${CLIENT_USER}@${CLIENT_IP} (Machine B)"
echo "  Client Scaph:   ${CLIENT_SCAPH_J} J"
echo "  Client Pstat:   ${CLIENT_PSTAT_J} J"
echo "============================================"
echo "  Workload batch complete. Instance still running."
echo "  Ready for next batch."
echo "============================================"
