#!/bin/bash
# =============================================================================
# start_edge_server.sh — Start Containernet edge server in server_only mode
# =============================================================================
# Starts topology.py in server_only mode (server container + switch only).
# iperf3 and HTTP servers run on the HOST so Machine B can reach them via
# the local network (192.168.1.x). Waits for topology_state.json to appear,
# verifies iperf3 reachability, then exits (topology continues in background).
#
# Usage:
#   bash start_edge_server.sh --session-id <id> --workload <type>
#
# Outputs on success:
#   EDGE_SERVER_READY <server_ip>
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
TOPOLOGY_SCRIPT="$PROJECT_DIR/topology/topology.py"
TMP_DIR="$PROJECT_DIR/tmp"
STATE_FILE="$TMP_DIR/topology_state.json"
PID_FILE="$TMP_DIR/topology_server_only.pid"

SESSION_ID=""
WORKLOAD="file_transfer"

while [[ $# -gt 0 ]]; do
    case $1 in
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --workload)   WORKLOAD="$2";   shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SESSION_ID" ]]; then
    echo "ERROR: --session-id is required"
    exit 1
fi

mkdir -p "$TMP_DIR"

# Remove stale state file from a previous run
rm -f "$STATE_FILE"

echo "  [start_edge_server] Starting topology in server_only mode..."
echo "  [start_edge_server] Session: $SESSION_ID  Workload: $WORKLOAD"

# Start topology in background
sudo python3 "$TOPOLOGY_SCRIPT" \
    --mode server_only \
    --session-id "$SESSION_ID" \
    --workload "$WORKLOAD" \
    > "$TMP_DIR/topology_server_only_${SESSION_ID}.log" 2>&1 &

TOPO_PID=$!
echo "$TOPO_PID" > "$PID_FILE"
echo "  [start_edge_server] topology.py PID: $TOPO_PID"

# Poll for state file (0.5s intervals, 60s timeout)
TIMEOUT=60
ELAPSED=0
while [[ ! -f "$STATE_FILE" ]]; do
    sleep 0.5
    ELAPSED=$(python3 -c "print($ELAPSED + 0.5)")

    # Check topology process is still alive
    if ! kill -0 "$TOPO_PID" 2>/dev/null; then
        echo "ERROR: topology.py exited unexpectedly before writing state file"
        echo "--- topology log ---"
        cat "$TMP_DIR/topology_server_only_${SESSION_ID}.log" 2>/dev/null || true
        exit 1
    fi

    if python3 -c "exit(0 if $ELAPSED < $TIMEOUT else 1)" 2>/dev/null; then
        :  # still within timeout
    else
        echo "ERROR: Timed out after ${TIMEOUT}s waiting for topology_state.json"
        kill "$TOPO_PID" 2>/dev/null || true
        exit 1
    fi
done

echo "  [start_edge_server] State file found after ${ELAPSED}s"

# Read server IP from state file
SERVER_IP=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['server_ip'])")
echo "  [start_edge_server] Server IP: $SERVER_IP"

# Give iperf3 an extra moment to bind before testing
sleep 1

# Verify iperf3 server is reachable (1-second test)
echo "  [start_edge_server] Verifying iperf3 connectivity..."
if iperf3 -c "$SERVER_IP" -t 1 -J > /dev/null 2>&1; then
    echo "  [start_edge_server] iperf3 server reachable OK"
else
    echo "WARNING: iperf3 connectivity check failed — server may still be starting"
    echo "         Proceeding anyway; Machine B will connect when ready."
fi

echo "EDGE_SERVER_READY $SERVER_IP"
