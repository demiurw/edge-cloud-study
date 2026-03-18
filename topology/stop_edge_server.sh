#!/bin/bash
# =============================================================================
# stop_edge_server.sh — Stop the server_only topology cleanly
# =============================================================================
# Sends SIGTERM to the background topology.py process, then runs mn -c to
# ensure Mininet state is fully cleaned up.
#
# Usage:
#   bash stop_edge_server.sh
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
TMP_DIR="$PROJECT_DIR/tmp"
STATE_FILE="$TMP_DIR/topology_state.json"
PID_FILE="$TMP_DIR/topology_server_only.pid"

echo "  [stop_edge_server] Stopping edge server topology..."

# Kill the topology.py background process via PID file
if [[ -f "$PID_FILE" ]]; then
    TOPO_PID=$(cat "$PID_FILE")
    if kill -0 "$TOPO_PID" 2>/dev/null; then
        echo "  [stop_edge_server] Sending SIGTERM to topology PID $TOPO_PID"
        sudo kill -TERM "$TOPO_PID" 2>/dev/null || true
        # Wait up to 15s for graceful shutdown
        for i in $(seq 1 30); do
            sleep 0.5
            if ! kill -0 "$TOPO_PID" 2>/dev/null; then
                echo "  [stop_edge_server] topology.py stopped (after ${i}x0.5s)"
                break
            fi
        done
        # Force kill if still running
        if kill -0 "$TOPO_PID" 2>/dev/null; then
            echo "  [stop_edge_server] Force-killing PID $TOPO_PID"
            sudo kill -9 "$TOPO_PID" 2>/dev/null || true
        fi
    else
        echo "  [stop_edge_server] PID $TOPO_PID not running (already stopped)"
    fi
    rm -f "$PID_FILE"
else
    echo "  [stop_edge_server] No PID file found — killing any topology.py process"
    sudo pkill -f "topology.py.*server_only" 2>/dev/null || true
fi

# Kill any stale iperf3/HTTP servers started by server_only mode
sudo pkill -x iperf3 2>/dev/null || true
sudo pkill -f "http.server 8080" 2>/dev/null || true
sleep 0.5

# Mininet cleanup
echo "  [stop_edge_server] Running mn -c cleanup..."
sudo mn -c 2>/dev/null || true

# Remove state file if still present
if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
    echo "  [stop_edge_server] Removed stale state file"
fi

echo "EDGE_SERVER_STOPPED"
