#!/usr/bin/env python3
"""
measure_client_energy.py — Subprocess Utility for Client Energy Measurement
=============================================================================
This script is designed to run as a subprocess wrapped around workload
execution. It automatically starts Scaphandre and PowerStat in the
background, signals the caller when ready, waits for a STOP signal via
stdin, stops the monitors, parses the logs, inserts the results into the
client_energy_runs table, and returns a JSON summary via stdout.

Usage (by caller script):
    python3 scripts/utils/measure_client_energy.py \
        --session-id <id> --environment <cloud|edge> \
        --workload <type> --size <size> --run-number <N>
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import threading
from datetime import datetime

PROJECT_DIR = "/home/dem/major_project/edge_cloud_study"
DB_PATH = f"{PROJECT_DIR}/data/results.db"
UTILS_DIR = f"{PROJECT_DIR}/scripts/utils"

def get_temp_log_paths(session_id, env, workload, run_num):
    base_name = f"{session_id}_{env}_{workload}_run{run_num}"
    scaph_path = f"/tmp/scaphandre_{base_name}.json"
    pstat_path = f"/tmp/powerstat_{base_name}.log"
    return scaph_path, pstat_path

def start_monitors(scaph_path, pstat_path):
    """Start Scaphandre and PowerStat in the background."""
    # Ensure any older files are removed
    if os.path.exists(scaph_path):
        os.remove(scaph_path)
    if os.path.exists(pstat_path):
        os.remove(pstat_path)

    scaph_cmd = f"scaphandre json -s 1 -f {scaph_path}"
    pstat_cmd = f"powerstat -R -z -d 0 1 3600 > {pstat_path} 2>&1"

    scaph_proc = subprocess.Popen(scaph_cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pstat_proc = subprocess.Popen(pstat_cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    return scaph_proc, pstat_proc

def stop_monitors(scaph_proc, pstat_proc):
    """Kill the background monitor processes."""
    # Using pkill is more robust since shell=True spawns a shell process
    subprocess.run("pkill -P " + str(pstat_proc.pid), shell=True, stderr=subprocess.DEVNULL)
    pstat_proc.terminate()
    try:
        pstat_proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pstat_proc.kill()

    subprocess.run("pkill -P " + str(scaph_proc.pid), shell=True, stderr=subprocess.DEVNULL)
    scaph_proc.terminate()
    try:
        scaph_proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        scaph_proc.kill()
        
    # Extra safety kill for the specific tools for this user
    subprocess.run("pkill scaphandre", shell=True, stderr=subprocess.DEVNULL)
    subprocess.run("pkill powerstat", shell=True, stderr=subprocess.DEVNULL)


def parse_output(scaph_path, pstat_path, duration):
    """Parse output using the existing utility scripts."""
    scaph_joules, pstat_joules, cpu_peak, cpu_avg = 0.0, 0.0, 0.0, 0.0
    
    try:
        rc = subprocess.run(
            ["python3", f"{UTILS_DIR}/parse_scaphandre.py", scaph_path, "--json-output"],
            capture_output=True, text=True
        )
        if rc.returncode == 0:
            data = json.loads(rc.stdout)
            scaph_joules = data.get("total_joules", 0.0)
            cpu_peak = data.get("peak_cpu_percent", 0.0)
            cpu_avg = data.get("avg_cpu_percent", 0.0)
    except Exception as e:
        print(f"Error parsing Scaphandre: {e}", file=sys.stderr)

    try:
        rc = subprocess.run(
            ["python3", f"{UTILS_DIR}/parse_powerstat.py", pstat_path, "--duration", str(duration), "--json-output"],
            capture_output=True, text=True
        )
        if rc.returncode == 0:
            data = json.loads(rc.stdout)
            pstat_joules = data.get("total_joules", 0.0)
            # Use PowerStat CPU if Scaphandre didn't get it (or overwrite it depending on preference, we prefer scaphandre CPU if available)
            if cpu_avg == 0.0:
                cpu_avg = data.get("avg_cpu_percent", 0.0)
    except Exception as e:
        print(f"Error parsing PowerStat: {e}", file=sys.stderr)

    return scaph_joules, pstat_joules, cpu_peak, cpu_avg


def insert_db(args, t_start, t_end, duration, data_sent, scaph_j, pstat_j, cpu_peak, cpu_avg):
    """Insert the result into the client_energy_runs table."""
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    # We set response_time_ms to NULL for now; it will be updated by the caller if applicable (e.g. for db queries)
    # data_sent_mb also placeholder if unknown
    cur.execute("""
        INSERT INTO client_energy_runs (
            session_id, environment, workload_type, workload_size_mb, run_number,
            timestamp_start, timestamp_end, duration_seconds, data_sent_mb,
            client_scaphandre_joules, client_powerstat_joules, client_cpu_peak_percent,
            client_cpu_avg_percent, response_time_ms, notes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
    """, (
        args.session_id, args.environment, args.workload, args.size, args.run_number,
        t_start, t_end, duration, data_sent,
        scaph_j, pstat_j, cpu_peak, cpu_avg
    ))
    run_id = cur.lastrowid
    conn.commit()
    conn.close()
    return run_id


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--environment", choices=["edge", "cloud"], required=True)
    parser.add_argument("--workload", required=True)
    parser.add_argument("--size", default="small")
    parser.add_argument("--run-number", type=int, required=True)
    
    args = parser.parse_args()

    scaph_path, pstat_path = get_temp_log_paths(args.session_id, args.environment, args.workload, args.run_number)
    
    scaph_proc, pstat_proc = start_monitors(scaph_path, pstat_path)
    
    # Needs a brief moment to initialize properly
    import time
    time.sleep(1)

    # Record start time and notify caller
    t_start_dt = datetime.now()
    t_start = t_start_dt.isoformat()
    
    print("MEASUREMENT_STARTED")
    sys.stdout.flush()

    # Wait for STOP signal from stdin
    try:
        for line in sys.stdin:
            if line.strip() == "STOP":
                break
    except KeyboardInterrupt:
        pass

    t_end_dt = datetime.now()
    t_end = t_end_dt.isoformat()
    duration = (t_end_dt - t_start_dt).total_seconds()

    stop_monitors(scaph_proc, pstat_proc)

    scaph_j, pstat_j, cpu_peak, cpu_avg = parse_output(scaph_path, pstat_path, duration)

    # Mock data sent for file transfer mapping, could be passed dynamically in the future
    size_mb_map = {"small": 10.0, "medium": 100.0, "large": 1000.0}
    data_sent = size_mb_map.get(args.size, 0.0) if args.workload == "file_transfer" else 0.0

    run_id = insert_db(args, t_start, t_end, duration, data_sent, scaph_j, pstat_j, cpu_peak, cpu_avg)

    # Clean up temp files
    if os.path.exists(scaph_path):
        os.remove(scaph_path)
    if os.path.exists(pstat_path):
        os.remove(pstat_path)

    # Print JSON summary
    summary = {
        "run_id": run_id,
        "duration_seconds": duration,
        "scaphandre_joules": scaph_j,
        "powerstat_joules": pstat_j,
        "cpu_peak_percent": cpu_peak,
        "cpu_avg_percent": cpu_avg
    }
    
    print(json.dumps(summary))

if __name__ == "__main__":
    main()
