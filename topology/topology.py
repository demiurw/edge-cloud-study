#!/usr/bin/env python3
"""
Containernet Campus Network Topology
=====================================
Emulates a university campus network with 5 department nodes connected
to a central server via a switch. Runs specified workloads and logs
iperf3 results to JSONL files.

Modes:
    full        — Full topology with server + 5 department containers.
                  Workloads run internally between dept1 and server.
    server_only — Server container + switch only. iperf3 and HTTP servers
                  run on the HOST so Machine B can reach them over the LAN
                  (192.168.1.x). Waits for SIGTERM before cleanup.

Usage:
    sudo python3 topology.py --workload file_transfer --size small --runs 3 --session-id test_001
    sudo python3 topology.py --mode server_only --session-id edge_001 --workload file_transfer &
"""

import argparse
import json
import re
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime

# Containernet / Mininet imports
from mininet.net import Containernet
from mininet.node import Controller
from mininet.cli import CLI
from mininet.link import TCLink
from mininet.log import info, setLogLevel

# --- Constants ---
PROJECT_DIR = "/home/dem/major_project/edge_cloud_study"
LOGS_DIR    = os.path.join(PROJECT_DIR, "logs", "iperf3")
TMP_DIR     = os.path.join(PROJECT_DIR, "tmp")
STATE_FILE  = os.path.join(TMP_DIR, "topology_state.json")
DOCKER_IMAGE = "edgecloud-workload:2.0"

# Workload sizes in bytes
FILE_SIZES = {
    "small":  10  * 1024 * 1024,   # 10 MB
    "medium": 100 * 1024 * 1024,   # 100 MB
    "large":  500 * 1024 * 1024,   # 500 MB
}

# --- Shutdown event (used by server_only mode) ---
_shutdown = threading.Event()


def _handle_signal(signum, frame):
    info("*** Received shutdown signal, initiating cleanup...\n")
    _shutdown.set()


def parse_args():
    parser = argparse.ArgumentParser(description="Containernet Campus Topology Workload Runner")
    parser.add_argument("--mode", default="full", choices=["full", "server_only"],
                        help="Topology mode: 'full' runs workloads internally; "
                             "'server_only' exposes server to LAN and waits (default: full)")
    parser.add_argument("--workload", default="file_transfer",
                        choices=["file_transfer", "video_encoding", "db_query", "web_request"],
                        help="Workload type to execute (required for full mode)")
    parser.add_argument("--size", default="small",
                        choices=["small", "medium", "large"],
                        help="Size for file_transfer workload (default: small)")
    parser.add_argument("--runs", type=int, default=1000,
                        help="Number of workload iterations (default: 1000)")
    parser.add_argument("--session-id", required=True,
                        help="Unique session identifier")
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Topology builders
# ---------------------------------------------------------------------------

def setup_full_topology():
    """Create and return the full campus network topology (server + 5 depts)."""
    setLogLevel("info")

    net = Containernet(controller=Controller)
    net.addController("c0")

    info("*** Adding central switch\n")
    s1 = net.addSwitch("s1")

    info("*** Adding server container\n")
    server = net.addDocker(
        "server", ip="10.0.0.100",
        dimage=DOCKER_IMAGE,
    )

    info("*** Adding department containers\n")
    departments = {}
    for i in range(1, 6):
        dept = net.addDocker(
            f"dept{i}", ip=f"10.0.0.{i}",
            dimage=DOCKER_IMAGE,
        )
        departments[f"dept{i}"] = dept

    info("*** Creating links (100Mbps, 5ms latency)\n")
    net.addLink(server, s1, cls=TCLink, bw=100, delay="5ms")
    for dept in departments.values():
        net.addLink(dept, s1, cls=TCLink, bw=100, delay="5ms")

    info("*** Starting network\n")
    net.start()

    # Quick readiness check
    info("*** Verifying container readiness...\n")
    for node in [server] + list(departments.values()):
        result = node.cmd("which iperf3").strip()
        if "iperf3" in result:
            info(f"    {node.name}: ready\n")
        else:
            info(f"    WARNING: {node.name}: iperf3 not found at '{result}'\n")

    return net, server, departments


def setup_server_only_topology():
    """Create topology with only the server container and switch."""
    setLogLevel("info")

    net = Containernet(controller=Controller)
    net.addController("c0")

    info("*** Adding central switch\n")
    s1 = net.addSwitch("s1")

    info("*** Adding server container (server_only mode)\n")
    server = net.addDocker(
        "server", ip="10.0.0.100",
        dimage=DOCKER_IMAGE,
    )

    net.addLink(server, s1, cls=TCLink, bw=100, delay="5ms")

    info("*** Starting network\n")
    net.start()

    result = server.cmd("which iperf3").strip()
    if "iperf3" in result:
        info("    server container: ready\n")
    else:
        info(f"    WARNING: server container: iperf3 not found\n")

    return net, server


# ---------------------------------------------------------------------------
# Server-only mode
# ---------------------------------------------------------------------------

def run_server_only_mode(args):
    """
    Start topology (server container + switch only), expose iperf3 and HTTP
    servers on the HOST so that Machine B can reach them over the LAN
    (192.168.1.x). Write topology_state.json and wait for SIGTERM.

    NOTE: Containernet overrides Docker's network namespace management, so
    Docker port_bindings cannot route external traffic into containers.
    Running iperf3/HTTP directly on the host guarantees LAN reachability
    while the topology provides the edge server environment.
    """
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT,  _handle_signal)

    os.makedirs(TMP_DIR, exist_ok=True)

    # Auto-detect local IP (the interface used for outbound traffic)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    local_ip = s.getsockname()[0]
    s.close()
    info(f"*** Detected local IP: {local_ip}\n")

    info("*** Starting server-only topology...\n")
    net, server = setup_server_only_topology()

    # Kill any stale servers before starting fresh
    subprocess.run(["pkill", "-x", "iperf3"],          capture_output=True)
    subprocess.run(["pkill", "-f", "http.server 8080"], capture_output=True)
    time.sleep(0.5)

    # Start iperf3 server on HOST bound to all interfaces.
    # Plain -s: stays running between sequential clients (no --one-off).
    # Note: --forking is not a valid flag on iperf3 3.x; -s is sufficient
    # since Machine B connects one run at a time sequentially.
    info("*** Starting iperf3 server on host (0.0.0.0:5201)...\n")
    subprocess.run(["pkill", "-x", "iperf3"], capture_output=True)  # kill stale
    time.sleep(0.3)
    iperf3_proc = subprocess.Popen(
        ["iperf3", "-s", "-p", "5201"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    # Start HTTP server on HOST
    info("*** Starting HTTP server on host (0.0.0.0:8080)...\n")
    # Create a small index file for web_request workload
    os.makedirs("/tmp/edge_http", exist_ok=True)
    with open("/tmp/edge_http/index.html", "w") as f:
        f.write("Hello from edge server\n")
    http_proc = subprocess.Popen(
        ["python3", "-m", "http.server", "8080"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        cwd="/tmp/edge_http",
    )

    time.sleep(1)  # Let servers come up before writing state

    # Write state file
    state = {
        "status":      "running",
        "server_ip":   local_ip,
        "iperf3_port": 5201,
        "http_port":   8080,
        "started_at":  datetime.now().isoformat(),
        "session_id":  args.session_id,
        "workload":    args.workload,
        "iperf3_pid":  iperf3_proc.pid,
        "http_pid":    http_proc.pid,
    }
    with open(STATE_FILE, "w") as fh:
        json.dump(state, fh, indent=2)

    info(f"*** State file written: {STATE_FILE}\n")
    info(f"*** Edge server READY at {local_ip}:5201 (iperf3), {local_ip}:8080 (http)\n")
    info("*** Waiting for SIGTERM to shut down...\n")

    # Block until SIGTERM / SIGINT
    _shutdown.wait()

    # ---- Cleanup ----
    info("*** Shutdown received, cleaning up...\n")
    try:
        iperf3_proc.terminate()
        http_proc.terminate()
        iperf3_proc.wait(timeout=5)
        http_proc.wait(timeout=5)
    except Exception:
        pass

    if os.path.exists(STATE_FILE):
        os.remove(STATE_FILE)
        info(f"*** Removed state file: {STATE_FILE}\n")

    info("*** Stopping Containernet network...\n")
    net.stop()
    os.system("sudo mn -c 2>/dev/null")
    info("*** Server-only topology shutdown complete.\n")


# ---------------------------------------------------------------------------
# Full-mode workload runners
# ---------------------------------------------------------------------------

def run_file_transfer(server, dept, size_bytes, run_number, session_id):
    """Run a single file transfer workload using iperf3."""
    server.cmd("pkill iperf3 2>/dev/null; sleep 0.2")
    server.cmd("iperf3 -s -D --one-off")
    time.sleep(0.5)

    server_ip = "10.0.0.100"
    timestamp_start = datetime.now().isoformat()

    raw_result = dept.cmd(f"iperf3 -c {server_ip} -n {size_bytes} -J 2>&1")
    timestamp_end = datetime.now().isoformat()

    result = re.sub(r'\x1b\[[^a-zA-Z]*[a-zA-Z]', '', raw_result)
    result = result.replace('\r', '')

    try:
        data = json.loads(result)
        sent = data.get("end", {}).get("sum_sent", {})
        duration         = sent.get("seconds", 0)
        bytes_sent       = sent.get("bytes", 0)
        bits_per_second  = sent.get("bits_per_second", 0)
        cpu_host         = data.get("end", {}).get("cpu_utilization_percent", {}).get("host_total", 0)

        return {
            "run_number":       run_number,
            "session_id":       session_id,
            "workload_type":    "file_transfer",
            "workload_size_mb": size_bytes / (1024 * 1024),
            "timestamp_start":  timestamp_start,
            "timestamp_end":    timestamp_end,
            "duration_seconds": duration,
            "data_sent_mb":     bytes_sent / (1024 * 1024),
            "bits_per_second":  bits_per_second,
            "cpu_percent":      cpu_host,
        }
    except json.JSONDecodeError:
        return {
            "run_number":       run_number,
            "session_id":       session_id,
            "workload_type":    "file_transfer",
            "workload_size_mb": size_bytes / (1024 * 1024),
            "timestamp_start":  timestamp_start,
            "timestamp_end":    timestamp_end,
            "error":            "Failed to parse iperf3 JSON output",
            "raw_output":       result[:2000],
        }


def run_video_encoding(server, dept, run_number, session_id):
    """Run a video encoding workload using ffmpeg."""
    timestamp_start = datetime.now().isoformat()

    dept.cmd("ffmpeg -y -f lavfi -i testsrc=duration=10:size=1280x720:rate=30 /tmp/test_input.mp4 2>/dev/null")

    start_t = time.time()
    dept.cmd("ffmpeg -y -i /tmp/test_input.mp4 -c:v libx264 -preset slow /tmp/output.mp4 2>/dev/null")
    elapsed = time.time() - start_t
    timestamp_end = datetime.now().isoformat()

    return {
        "run_number":       run_number,
        "session_id":       session_id,
        "workload_type":    "video_encoding",
        "workload_size_mb": 50.0,
        "timestamp_start":  timestamp_start,
        "timestamp_end":    timestamp_end,
        "duration_seconds": elapsed,
        "data_sent_mb":     50.0,
        "cpu_percent":      0,
    }


def run_db_query(server, dept, run_number, session_id):
    """Run database query workload — 100 SELECT queries on synthetic data."""
    timestamp_start = datetime.now().isoformat()

    server.cmd("""python3 -c "
import sqlite3, random, string
conn = sqlite3.connect('/tmp/test_students.db')
c = conn.cursor()
c.execute('CREATE TABLE IF NOT EXISTS students (id INT, name TEXT, dept TEXT, gpa REAL, year INT)')
if c.execute('SELECT COUNT(*) FROM students').fetchone()[0] < 100000:
    data = []
    for i in range(100000):
        name = ''.join(random.choices(string.ascii_letters, k=10))
        dept = random.choice(['CS','EE','ME','CE','BIO'])
        gpa = round(random.uniform(2.0, 4.0), 2)
        year = random.randint(1, 4)
        data.append((i, name, dept, gpa, year))
    c.executemany('INSERT INTO students VALUES (?,?,?,?,?)', data)
    conn.commit()
conn.close()
" 2>/dev/null""")

    start_t = time.time()
    server.cmd("""python3 -c "
import sqlite3
conn = sqlite3.connect('/tmp/test_students.db')
c = conn.cursor()
for i in range(100):
    c.execute('SELECT s.name, s.dept, s.gpa FROM students s WHERE s.dept = \"CS\" AND s.gpa > 3.5 AND s.year >= 3 ORDER BY s.gpa DESC LIMIT 50')
    _ = c.fetchall()
conn.close()
" 2>/dev/null""")
    elapsed = time.time() - start_t
    timestamp_end = datetime.now().isoformat()

    return {
        "run_number":       run_number,
        "session_id":       session_id,
        "workload_type":    "db_query",
        "workload_size_mb": 5.0,
        "timestamp_start":  timestamp_start,
        "timestamp_end":    timestamp_end,
        "duration_seconds": elapsed,
        "data_sent_mb":     5.0,
        "request_count":    100,
    }


def run_web_request(server, dept, run_number, session_id):
    """Run web request workload — 50 HTTP GET requests."""
    timestamp_start = datetime.now().isoformat()

    server.cmd("pkill -f 'python3 -m http.server 8080' 2>/dev/null")
    server.cmd("cd /tmp && echo 'Hello from edge server' > index.html && python3 -m http.server 8080 &")
    time.sleep(1)

    server_ip = "10.0.0.100"
    start_t = time.time()

    result = dept.cmd(f"""python3 -c "
import urllib.request, time
total_bytes = 0
times = []
for i in range(50):
    t0 = time.time()
    resp = urllib.request.urlopen('http://{server_ip}:8080/index.html')
    data = resp.read()
    total_bytes += len(data)
    times.append((time.time() - t0) * 1000)
print(f'BYTES:{{total_bytes}}')
print(f'AVG_MS:{{sum(times)/len(times):.2f}}')
" 2>&1""")

    elapsed = time.time() - start_t
    timestamp_end = datetime.now().isoformat()

    total_bytes = 0
    avg_ms = 0
    for line in result.strip().split("\n"):
        if line.startswith("BYTES:"):
            total_bytes = int(line.split(":")[1])
        elif line.startswith("AVG_MS:"):
            avg_ms = float(line.split(":")[1])

    return {
        "run_number":         run_number,
        "session_id":         session_id,
        "workload_type":      "web_request",
        "workload_size_mb":   total_bytes / (1024 * 1024) if total_bytes > 0 else 0,
        "timestamp_start":    timestamp_start,
        "timestamp_end":      timestamp_end,
        "duration_seconds":   elapsed,
        "data_sent_mb":       total_bytes / (1024 * 1024) if total_bytes > 0 else 0,
        "request_count":      50,
        "avg_response_time_ms": avg_ms,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    if args.mode == "server_only":
        run_server_only_mode(args)
        return

    # ---- full mode (existing behaviour) ----
    os.makedirs(LOGS_DIR, exist_ok=True)

    size_suffix = f"_{args.size}" if args.workload == "file_transfer" else ""
    output_file = os.path.join(LOGS_DIR, f"{args.session_id}_{args.workload}{size_suffix}.jsonl")

    info(f"*** Session: {args.session_id}\n")
    info(f"*** Workload: {args.workload} (size: {args.size})\n")
    info(f"*** Runs: {args.runs}\n")
    info(f"*** Output: {output_file}\n")

    net, server, departments = setup_full_topology()

    try:
        dept1 = departments["dept1"]

        workload_runners = {
            "file_transfer": lambda rn: run_file_transfer(
                server, dept1, FILE_SIZES.get(args.size, FILE_SIZES["small"]), rn, args.session_id
            ),
            "video_encoding": lambda rn: run_video_encoding(server, dept1, rn, args.session_id),
            "db_query":       lambda rn: run_db_query(server, dept1, rn, args.session_id),
            "web_request":    lambda rn: run_web_request(server, dept1, rn, args.session_id),
        }

        runner = workload_runners[args.workload]

        info(f"\n*** Starting {args.runs} workload runs\n")

        with open(output_file, "w") as f:
            for run_num in range(1, args.runs + 1):
                info(f"  Run {run_num}/{args.runs}...")
                result = runner(run_num)
                f.write(json.dumps(result) + "\n")
                f.flush()

                duration = result.get("duration_seconds", 0)
                error    = result.get("error", None)
                if error:
                    info(f" ERROR: {error}\n")
                else:
                    info(f" done ({duration:.2f}s)\n")

        info(f"\n*** All {args.runs} runs completed. Results in: {output_file}\n")

    except Exception as e:
        info(f"\n*** ERROR: {e}\n")
        import traceback
        traceback.print_exc()
        raise
    finally:
        info("*** Cleaning up topology\n")
        net.stop()
        os.system("sudo mn -c 2>/dev/null")
        info("*** Topology shutdown complete\n")


if __name__ == "__main__":
    main()
