#!/bin/bash
# =============================================================================
# run_cloud_workload.sh — Execute Workloads on GCP e2-micro
# =============================================================================
# Runs workloads on the cloud instance via SSH while polling the GCP Monitoring
# API for CPU/bandwidth metrics. Results go into the cloud_runs table.
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
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --workload) WORKLOAD="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --instance-ip) INSTANCE_IP="$2"; shift 2 ;;
        --project-id) PROJECT_ID="$2"; shift 2 ;;
        --instance-id) INSTANCE_ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SESSION_ID" ]] || [[ -z "$WORKLOAD" ]] || [[ -z "$INSTANCE_IP" ]] || [[ -z "$PROJECT_ID" ]] || [[ -z "$INSTANCE_ID" ]]; then
    echo "ERROR: --session-id, --workload, --instance-ip, --project-id, and --instance-id are required"
    exit 1
fi

ZONE="us-central1-a"  # Hardcoded or passed, assuming default for now

mkdir -p "$LOGS_CLOUD" "$EXPORTS_DIR"

# File sizes mapping
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
echo "============================================"

# --- Ensure iperf3 server is running on Instance ---
echo "[1/3] Verifying GCP instance iperf3 server..."
ssh -o StrictHostKeyChecking=no "ubuntu@$INSTANCE_IP" "pkill iperf3 2>/dev/null; iperf3 -s -D" 2>/dev/null || true

# --- Run workloads ---
echo "[2/3] Running $RUNS cloud workload iterations..."

> "$CLOUD_LOG"  # Clear log files
> "$GCP_LOG"

# Start background metric polling loop
METRIC_TMP="/tmp/gcp_metrics_${SESSION_ID}.txt"
> "$METRIC_TMP"

python3 << 'EOF' > "$METRIC_TMP" &
from google.cloud import monitoring_v3
from google.api_core.datetime_helpers import DatetimeWithNanoseconds
import time, json, sys, os

project_id = os.environ.get("PROJECT_ID", "")
instance_id = os.environ.get("INSTANCE_ID", "")
gcp_log = os.environ.get("GCP_LOG", "/dev/null")

if not project_id:
    sys.exit(0)

try:
    client = monitoring_v3.MetricServiceClient()
    project_name = f"projects/{project_id}"
except Exception as e:
    with open(gcp_log, "a") as f:
        f.write(json.dumps({"error": str(e)}) + "\n")
    sys.exit(1)

cpu_filter = f'metric.type="compute.googleapis.com/instance/cpu/utilization" AND resource.labels.instance_id="{instance_id}"'

while True:
    now = time.time()
    interval = monitoring_v3.TimeInterval()
    interval.end_time.seconds = int(now)
    interval.start_time.seconds = int(now) - 60

    try:
        results = client.list_time_series(
            request={"name": project_name, "filter": cpu_filter, "interval": interval,
                     "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL}
        )
        for result in results:
            for point in result.points:
                with open(gcp_log, "a") as f:
                    f.write(json.dumps({
                        "metric": "cpu_utilization",
                        "value": point.value.double_value,
                        "timestamp": point.interval.end_time.seconds
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

for run_num in $(seq 1 "$RUNS"); do
    TIMESTAMP_START=$(date -Iseconds)
    START_MS=$(date +%s%N | cut -b1-13)

    if [[ "$WORKLOAD" == "file_transfer" ]]; then
        SIZE_BYTES=${FILE_SIZES[$SIZE]}
        RESULT=$(iperf3 -c "$INSTANCE_IP" -n "$SIZE_BYTES" -J 2>&1 || echo '{}')
        END_MS=$(date +%s%N | cut -b1-13)
        TIMESTAMP_END=$(date -Iseconds)

        python3 -c "
import json, sys
try:
    data = json.loads('''$RESULT''')
    sent = data.get('end', {}).get('sum_sent', {})
    duration = sent.get('seconds', 0)
    bytes_sent = sent.get('bytes', 0)
    bps = sent.get('bits_per_second', 0)
    cpu = data.get('end', {}).get('cpu_utilization_percent', {}).get('host_total', 0)
    entry = {
        'run_number': $run_num,
        'session_id': '$SESSION_ID',
        'workload_type': 'file_transfer',
        'workload_size_mb': $SIZE_BYTES / (1024*1024),
        'timestamp_start': '$TIMESTAMP_START',
        'timestamp_end': '$TIMESTAMP_END',
        'duration_seconds': duration,
        'data_sent_mb': bytes_sent / (1024*1024),
        'bandwidth_out_mb': bps / (8*1024*1024),
        'response_time_ms': ($END_MS - $START_MS),
        'cpu_avg_percent': cpu,
        'request_count': 1,
    }
except:
    entry = {
        'run_number': $run_num,
        'session_id': '$SESSION_ID',
        'workload_type': 'file_transfer',
        'error': 'parse_failed',
        'timestamp_start': '$TIMESTAMP_START',
        'timestamp_end': '$TIMESTAMP_END',
    }
print(json.dumps(entry))
" >> "$CLOUD_LOG"

    elif [[ "$WORKLOAD" == "web_request" ]]; then
        python3 -c "
import urllib.request, json, time
start = time.time()
total_bytes = 0
times = []
for i in range(50):
    t0 = time.time()
    try:
        resp = urllib.request.urlopen('http://$INSTANCE_IP:8080/', timeout=10)
        data = resp.read()
        total_bytes += len(data)
        times.append((time.time() - t0) * 1000)
    except: pass
elapsed = time.time() - start
avg_ms = sum(times)/len(times) if times else 0
entry = {
    'run_number': $run_num,
    'session_id': '$SESSION_ID',
    'workload_type': 'web_request',
    'workload_size_mb': total_bytes / (1024*1024),
    'timestamp_start': '$TIMESTAMP_START',
    'timestamp_end': '$(date -Iseconds)',
    'duration_seconds': elapsed,
    'data_sent_mb': total_bytes / (1024*1024),
    'bandwidth_out_mb': (total_bytes / (1024*1024)) / elapsed if elapsed > 0 else 0,
    'response_time_ms': avg_ms,
    'cpu_avg_percent': 0,
    'request_count': 50,
}
print(json.dumps(entry))
" >> "$CLOUD_LOG"

    else
        # For video_encoding and db_query, run on the remote instance
        REMOTE_RESULT=$(ssh -o StrictHostKeyChecking=no "ubuntu@$INSTANCE_IP" \
            "python3 -c \"
import time, json
start = time.time()
if '$WORKLOAD' == 'video_encoding':
    import subprocess
    subprocess.run(['ffmpeg', '-y', '-f', 'lavfi', '-i', 'testsrc=duration=10:size=1280x720:rate=30', '/tmp/test.mp4'], capture_output=True)
    subprocess.run(['ffmpeg', '-y', '-i', '/tmp/test.mp4', '-c:v', 'libx264', '-preset', 'slow', '/tmp/out.mp4'], capture_output=True)
elif '$WORKLOAD' == 'db_query':
    import sqlite3, random, string
    conn = sqlite3.connect('/tmp/test.db')
    c = conn.cursor()
    c.execute('CREATE TABLE IF NOT EXISTS t (id INT, name TEXT, val REAL)')
    if c.execute('SELECT COUNT(*) FROM t').fetchone()[0] < 100000:
        c.executemany('INSERT INTO t VALUES (?,?,?)', [(i,''.join(random.choices(string.ascii_letters,k=8)),random.random()) for i in range(100000)])
        conn.commit()
    for _ in range(100):
        c.execute('SELECT * FROM t WHERE val > 0.5 ORDER BY val LIMIT 50')
        c.fetchall()
    conn.close()
elapsed = time.time() - start
print(json.dumps({'duration': elapsed}))
\"" 2>/dev/null || echo '{"duration": 0}')

        DURATION=$(echo "$REMOTE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('duration',0))")
        TIMESTAMP_END=$(date -Iseconds)

        python3 -c "
import json
entry = {
    'run_number': $run_num,
    'session_id': '$SESSION_ID',
    'workload_type': '$WORKLOAD',
    'workload_size_mb': 50 if '$WORKLOAD' == 'video_encoding' else 5,
    'timestamp_start': '$TIMESTAMP_START',
    'timestamp_end': '$TIMESTAMP_END',
    'duration_seconds': $DURATION,
    'data_sent_mb': 0,
    'bandwidth_out_mb': 0,
    'response_time_ms': $DURATION * 1000,
    'cpu_avg_percent': 0,
    'request_count': 100 if '$WORKLOAD' == 'db_query' else 1,
}
print(json.dumps(entry))
" >> "$CLOUD_LOG"
    fi

    echo "  Run $run_num/$RUNS done"
done

kill -9 $POLL_PID 2>/dev/null || true

# --- Insert into database ---
echo "[3/3] Inserting results into cloud_runs table..."

python3 << PYEOF
import json, sqlite3

db = sqlite3.connect("$DB_PATH")
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
            r.get("session_id"), r.get("workload_type"),
            r.get("workload_size_mb", 0), r.get("run_number", 0),
            r.get("timestamp_start", ""), r.get("timestamp_end", ""),
            r.get("duration_seconds", 0), r.get("data_sent_mb", 0),
            r.get("bandwidth_out_mb", 0), r.get("response_time_ms", 0),
            r.get("cpu_avg_percent", 0), r.get("request_count", 0),
            None,
        ))

db.commit()
count = cur.execute("SELECT COUNT(*) FROM cloud_runs WHERE session_id=?", ("$SESSION_ID",)).fetchone()[0]
print(f"Inserted {count} cloud runs into database")
db.close()
PYEOF

# Export CSV
CSV_FILE="$EXPORTS_DIR/${SESSION_ID}_cloud.csv"
sqlite3 -header -csv "$DB_PATH" \
    "SELECT * FROM cloud_runs WHERE session_id='$SESSION_ID';" > "$CSV_FILE"

# --- Between-workload Cleanup ---
echo "[4/4] Performing between-workload cleanup..."

# 1. Restart iperf3 server
gcloud compute ssh edgecloud-server --zone="$ZONE" --project="$PROJECT_ID" \
    --command="pkill iperf3 2>/dev/null; sleep 2; nohup iperf3 -s -D >/dev/null 2>&1 &" \
    --quiet 2>/dev/null || true

# 2. Verify instance is still healthy
if ! gcloud compute ssh edgecloud-server --zone="$ZONE" --project="$PROJECT_ID" --command="echo OK" --quiet >/dev/null 2>&1; then
    echo "  WARNING: GCP instance health check failed after workload batch."
    echo "           Please verify instance state before continuing."
fi

# 3. Log boundary timestamp
BOUNDARIES_LOG="$LOGS_CLOUD/workload_boundaries.log"
TIMESTAMP_BOUNDARY=$(date -Iseconds)
echo "${SESSION_ID} | ${WORKLOAD} | completed | ${TIMESTAMP_BOUNDARY}" >> "$BOUNDARIES_LOG"

echo ""
echo "============================================"
echo "  CLOUD WORKLOAD COMPLETE (GCP)"
echo "============================================"
echo "  Runs:     $RUNS"
echo "  Log:      $CLOUD_LOG"
echo "  GCP Log:  $GCP_LOG"
echo "  CSV:      $CSV_FILE"
echo "============================================"
echo "  Workload batch complete. Instance still running."
echo "  Ready for next batch."
echo "============================================"
