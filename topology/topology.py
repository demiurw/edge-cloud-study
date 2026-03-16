#!/usr/bin/env python3
"""
Containernet Campus Network Topology
=====================================
Emulates a university campus network with 5 department nodes connected
to a central server via a switch. Runs specified workloads and logs
iperf3 results to JSONL files.

Usage:
    sudo python3 topology.py --workload file_transfer --size small --runs 3 --session-id test_001
"""

import argparse
import json
import re
import os
import sys
import time
import subprocess
from datetime import datetime

# Containernet / Mininet imports
from mininet.net import Containernet
from mininet.node import Controller
from mininet.cli import CLI
from mininet.link import TCLink
from mininet.log import info, setLogLevel

# --- Constants ---
PROJECT_DIR = "/home/dem/major_project/edge_cloud_study"
LOGS_DIR = os.path.join(PROJECT_DIR, "logs", "iperf3")
DOCKER_IMAGE = "edgecloud-workload:2.0"

# Workload sizes in bytes
FILE_SIZES = {
    "small": 10 * 1024 * 1024,       # 10 MB
    "medium": 100 * 1024 * 1024,      # 100 MB
    "large": 500 * 1024 * 1024,       # 500 MB
}


def parse_args():
    parser = argparse.ArgumentParser(description="Containernet Campus Topology Workload Runner")
    parser.add_argument("--workload", required=True,
                        choices=["file_transfer", "video_encoding", "db_query", "web_request"],
                        help="Workload type to execute")
    parser.add_argument("--size", default="small",
                        choices=["small", "medium", "large"],
                        help="Size for file_transfer workload (default: small)")
    parser.add_argument("--runs", type=int, default=1000,
                        help="Number of workload iterations (default: 1000)")
    parser.add_argument("--session-id", required=True,
                        help="Unique session identifier")
    return parser.parse_args()


def setup_topology():
    """Create and return the campus network topology."""
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

    # Quick readiness check — just verify iperf3 is accessible
    info("*** Verifying container readiness...\n")
    for node in [server] + list(departments.values()):
        result = node.cmd("which iperf3").strip()
        if "iperf3" in result:
            info(f"    {node.name}: ready\n")
        else:
            info(f"    WARNING: {node.name}: iperf3 not found at '{result}'\n")

    return net, server, departments


def run_file_transfer(server, dept, size_bytes, run_number, session_id):
    """Run a single file transfer workload using iperf3."""
    # Start iperf3 server (daemon, single client mode)
    server.cmd("pkill iperf3 2>/dev/null; sleep 0.2")
    server.cmd("iperf3 -s -D --one-off")
    time.sleep(0.5)

    server_ip = "10.0.0.100"
    timestamp_start = datetime.now().isoformat()

    # Run iperf3 client — transfer exactly size_bytes
    raw_result = dept.cmd(f"iperf3 -c {server_ip} -n {size_bytes} -J 2>&1")
    timestamp_end = datetime.now().isoformat()

    # Strip ANSI escape codes and carriage returns from container output
    result = re.sub(r'\x1b\[[^a-zA-Z]*[a-zA-Z]', '', raw_result)
    result = result.replace('\r', '')

    try:
        data = json.loads(result)
        sent = data.get("end", {}).get("sum_sent", {})
        duration = sent.get("seconds", 0)
        bytes_sent = sent.get("bytes", 0)
        bits_per_second = sent.get("bits_per_second", 0)
        cpu_host = data.get("end", {}).get("cpu_utilization_percent", {}).get("host_total", 0)

        return {
            "run_number": run_number,
            "session_id": session_id,
            "workload_type": "file_transfer",
            "workload_size_mb": size_bytes / (1024 * 1024),
            "timestamp_start": timestamp_start,
            "timestamp_end": timestamp_end,
            "duration_seconds": duration,
            "data_sent_mb": bytes_sent / (1024 * 1024),
            "bits_per_second": bits_per_second,
            "cpu_percent": cpu_host,
        }
    except json.JSONDecodeError:
        return {
            "run_number": run_number,
            "session_id": session_id,
            "workload_type": "file_transfer",
            "workload_size_mb": size_bytes / (1024 * 1024),
            "timestamp_start": timestamp_start,
            "timestamp_end": timestamp_end,
            "error": "Failed to parse iperf3 JSON output",
            "raw_output": result[:2000],
        }


def run_video_encoding(server, dept, run_number, session_id):
    """Run a video encoding workload using ffmpeg."""
    timestamp_start = datetime.now().isoformat()

    # Generate test video on dept node
    dept.cmd("ffmpeg -y -f lavfi -i testsrc=duration=10:size=1280x720:rate=30 /tmp/test_input.mp4 2>/dev/null")

    # Transcode
    start_t = time.time()
    dept.cmd("ffmpeg -y -i /tmp/test_input.mp4 -c:v libx264 -preset slow /tmp/output.mp4 2>/dev/null")
    elapsed = time.time() - start_t
    timestamp_end = datetime.now().isoformat()

    return {
        "run_number": run_number,
        "session_id": session_id,
        "workload_type": "video_encoding",
        "workload_size_mb": 50.0,
        "timestamp_start": timestamp_start,
        "timestamp_end": timestamp_end,
        "duration_seconds": elapsed,
        "data_sent_mb": 50.0,
        "cpu_percent": 0,
    }


def run_db_query(server, dept, run_number, session_id):
    """Run database query workload — 100 SELECT queries on synthetic data."""
    timestamp_start = datetime.now().isoformat()

    # Create test database on server if not exists
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

    # Execute 100 queries
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
        "run_number": run_number,
        "session_id": session_id,
        "workload_type": "db_query",
        "workload_size_mb": 5.0,
        "timestamp_start": timestamp_start,
        "timestamp_end": timestamp_end,
        "duration_seconds": elapsed,
        "data_sent_mb": 5.0,
        "request_count": 100,
    }


def run_web_request(server, dept, run_number, session_id):
    """Run web request workload — 50 HTTP GET requests."""
    timestamp_start = datetime.now().isoformat()

    # Start HTTP server on the server node (kill any existing first)
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
        "run_number": run_number,
        "session_id": session_id,
        "workload_type": "web_request",
        "workload_size_mb": total_bytes / (1024 * 1024) if total_bytes > 0 else 0,
        "timestamp_start": timestamp_start,
        "timestamp_end": timestamp_end,
        "duration_seconds": elapsed,
        "data_sent_mb": total_bytes / (1024 * 1024) if total_bytes > 0 else 0,
        "request_count": 50,
        "avg_response_time_ms": avg_ms,
    }


def main():
    args = parse_args()
    os.makedirs(LOGS_DIR, exist_ok=True)

    size_suffix = f"_{args.size}" if args.workload == "file_transfer" else ""
    output_file = os.path.join(LOGS_DIR, f"{args.session_id}_{args.workload}{size_suffix}.jsonl")

    info(f"*** Session: {args.session_id}\n")
    info(f"*** Workload: {args.workload} (size: {args.size})\n")
    info(f"*** Runs: {args.runs}\n")
    info(f"*** Output: {output_file}\n")

    net, server, departments = setup_topology()

    try:
        dept1 = departments["dept1"]

        # Dispatch table for workload runners
        workload_runners = {
            "file_transfer": lambda rn: run_file_transfer(
                server, dept1, FILE_SIZES.get(args.size, FILE_SIZES["small"]), rn, args.session_id
            ),
            "video_encoding": lambda rn: run_video_encoding(server, dept1, rn, args.session_id),
            "db_query": lambda rn: run_db_query(server, dept1, rn, args.session_id),
            "web_request": lambda rn: run_web_request(server, dept1, rn, args.session_id),
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
                error = result.get("error", None)
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
