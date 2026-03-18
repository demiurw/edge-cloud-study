#!/usr/bin/env python3
"""
Pipeline Validation Script
============================
Runs end-to-end validation of the entire experiment pipeline using
minimal iterations (3 runs) to confirm everything works before
committing to 1,000-run batches.

Usage:
    sudo python3 validate_pipeline.py [--skip-cloud]
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime

PROJECT_DIR = "/home/dem/major_project/edge_cloud_study"
DB_PATH = f"{PROJECT_DIR}/data/results.db"
MEMORY_FILE = f"{PROJECT_DIR}/AGENT_MEMORY.json"
TOPOLOGY_SCRIPT = f"{PROJECT_DIR}/topology/topology.py"
SCRIPTS_EDGE = f"{PROJECT_DIR}/scripts/edge"
UTILS_DIR = f"{PROJECT_DIR}/scripts/utils"

VALIDATION_SESSION = "validate_pipeline_001"


class ValidationResult:
    def __init__(self):
        self.checks = []

    def add(self, name, passed, message=""):
        status = "PASS" if passed else "FAIL"
        self.checks.append({"name": name, "status": status, "message": message})
        icon = "✅" if passed else "❌"
        print(f"  {icon} {name}: {status} {f'— {message}' if message else ''}")

    def summary(self):
        total = len(self.checks)
        passed = sum(1 for c in self.checks if c["status"] == "PASS")
        failed = total - passed
        return total, passed, failed


def run_cmd(cmd, timeout=300):
    """Run a command and return (returncode, stdout, stderr)."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"


def main():
    parser = argparse.ArgumentParser(description="Validate experiment pipeline")
    parser.add_argument("--skip-cloud", action="store_true",
                        help="Skip cloud-related checks")
    args = parser.parse_args()

    print("=" * 60)
    print("  Pipeline Validation")
    print("  " + datetime.now().isoformat())
    print("=" * 60)

    v = ValidationResult()

    # === CHECK 1: Project structure ===
    print("\n--- Project Structure ---")
    required_dirs = [
        "scripts/edge", "scripts/cloud", "scripts/analysis", "scripts/utils",
        "data", "data/raw", "logs/scaphandre", "logs/powerstat",
        "logs/powertop", "logs/iperf3", "logs/cloud", "exports", "topology"
    ]
    for d in required_dirs:
        path = os.path.join(PROJECT_DIR, d)
        v.add(f"Directory: {d}", os.path.isdir(path))

    # === CHECK 2: Required files ===
    print("\n--- Required Files ---")
    required_files = [
        "AGENT_MEMORY.json",
        "data/results.db",
        "topology/topology.py",
        "topology/inject_latency.py",
        "scripts/edge/capture_baseline.sh",
        "scripts/edge/capture_client_baseline.sh",
        "scripts/edge/run_workload.sh",
        "scripts/utils/parse_scaphandre.py",
        "scripts/utils/parse_powerstat.py",
        "scripts/utils/measure_client_energy.py",
        "scripts/cloud/setup_gcp_instance.sh",
        "scripts/cloud/run_cloud_workload.sh",
        "scripts/cloud/fetch_gcp_energy.py",
        "scripts/cloud/teardown_gcp_instance.sh",
        "scripts/run_experiment.py",
        "scripts/analysis/compare_results.py",
        "scripts/analysis/compare_client_energy.py",
    ]
    for f in required_files:
        path = os.path.join(PROJECT_DIR, f)
        v.add(f"File: {f}", os.path.isfile(path))

    # === CHECK 3: SQLite database tables ===
    print("\n--- Database Tables ---")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    expected_tables = ["edge_runs", "edge_baselines", "cloud_runs", "cloud_reported_energy", "sessions", "client_energy_runs", "client_energy_baselines"]
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    existing_tables = [row[0] for row in cur.fetchall()]
    for t in expected_tables:
        v.add(f"Table: {t}", t in existing_tables)

    # Verify new schema directly
    if "client_energy_runs" in existing_tables:
        cur.execute("PRAGMA table_info(client_energy_runs)")
        cols = [r[1] for r in cur.fetchall()]
        v.add("client_energy_runs schema", "client_scaphandre_joules" in cols and "client_cpu_peak_percent" in cols)
    else:
        v.add("client_energy_runs schema", False)

    # === CHECK 4: Tool availability ===
    print("\n--- Tool Availability ---")
    tools = {
        "docker": "docker --version",
        "python3": "python3 --version",
        "iperf3": "iperf3 --version 2>&1 | head -1",
        "scaphandre": "scaphandre --version",
        "powerstat": "powerstat -h 2>&1 | head -1",
        "powertop": "powertop --version 2>&1",
        "sqlite3": "sqlite3 --version",
        "jq": "jq --version",
        "gcloud": "gcloud --version",
    }
    for name, cmd in tools.items():
        rc, out, _ = run_cmd(cmd, timeout=10)
        v.add(f"Tool: {name}", rc == 0, out.strip()[:50] if rc == 0 else "NOT FOUND")

    # === CHECK 5: RAPL availability ===
    print("\n--- Energy Monitoring ---")
    rapl_path = "/sys/class/powercap/intel-rapl/"
    v.add("RAPL available", os.path.isdir(rapl_path),
          "Full hardware accuracy" if os.path.isdir(rapl_path) else "Reduced accuracy")

    # === CHECK 6: Containernet import ===
    print("\n--- Containernet ---")
    rc, out, err = run_cmd("python3 -c 'from mininet.net import Containernet; print(\"OK\")'")
    v.add("Containernet import", rc == 0 and "OK" in out)

    # === CHECK 7: Docker image ===
    rc, out, _ = run_cmd("docker images --format '{{.Repository}}:{{.Tag}}' | grep edgecloud-workload")
    v.add("Docker image: edgecloud-workload", rc == 0 and "edgecloud-workload" in out,
          out.strip()[:50] if out else "NOT FOUND")

    # === CHECK 8: Topology test (3 runs, full mode) ===
    print("\n--- Topology Validation (3 runs, full mode) ---")
    print("  Running topology test... (this may take 1-2 minutes)")
    run_cmd("sudo mn -c 2>/dev/null", timeout=30)

    rc, out, err = run_cmd(
        f"sudo python3 {TOPOLOGY_SCRIPT} --workload file_transfer --size small "
        f"--runs 3 --session-id {VALIDATION_SESSION}",
        timeout=300
    )
    v.add("Topology full mode runs successfully", rc == 0,
          f"exit code {rc}" if rc != 0 else "3 runs completed")

    # Check JSONL output
    jsonl_path = f"{PROJECT_DIR}/logs/iperf3/{VALIDATION_SESSION}_file_transfer_small.jsonl"
    if os.path.isfile(jsonl_path):
        with open(jsonl_path) as f:
            lines = f.readlines()
        v.add("JSONL output created", len(lines) == 3, f"{len(lines)} entries")

        valid_runs = 0
        for line in lines:
            try:
                entry = json.loads(line)
                if "error" not in entry and entry.get("duration_seconds", 0) > 0:
                    valid_runs += 1
            except json.JSONDecodeError:
                pass
        v.add("All runs parsed successfully", valid_runs == 3, f"{valid_runs}/3 valid")
    else:
        v.add("JSONL output created", False, "File not found")
        v.add("All runs parsed successfully", False, "No data")

    run_cmd("sudo mn -c 2>/dev/null", timeout=30)

    # === CHECK 8b: topology.py --mode argument ===
    print("\n--- Topology server_only Mode ---")
    rc, out, err = run_cmd(
        f"python3 {TOPOLOGY_SCRIPT} --help", timeout=10
    )
    v.add("topology.py accepts --mode argument", rc == 0 and "--mode" in out,
          "--mode found in --help" if "--mode" in out else "--mode NOT in --help")

    # Check start/stop scripts exist and are executable
    start_sh = os.path.join(PROJECT_DIR, "topology", "start_edge_server.sh")
    stop_sh  = os.path.join(PROJECT_DIR, "topology", "stop_edge_server.sh")
    v.add("topology/start_edge_server.sh exists",
          os.path.isfile(start_sh))
    v.add("topology/start_edge_server.sh is executable",
          os.access(start_sh, os.X_OK))
    v.add("topology/stop_edge_server.sh exists",
          os.path.isfile(stop_sh))
    v.add("topology/stop_edge_server.sh is executable",
          os.access(stop_sh, os.X_OK))

    # === CHECK 9: Parser utilities ===
    print("\n--- Parser Utilities ---")
    rc, _, _ = run_cmd(f"python3 {UTILS_DIR}/parse_scaphandre.py --help")
    v.add("parse_scaphandre.py loads", rc == 0)

    rc, _, _ = run_cmd(f"python3 {UTILS_DIR}/parse_powerstat.py --help")
    v.add("parse_powerstat.py loads", rc == 0)

    # === CHECK 10: AGENT_MEMORY.json ===
    print("\n--- Memory File ---")
    try:
        with open(MEMORY_FILE) as f:
            mem = json.load(f)
        v.add("AGENT_MEMORY.json valid JSON", True)
        v.add("Memory has required keys", all(k in mem for k in ["project", "phase", "environment", "experiment"]))
    except (json.JSONDecodeError, FileNotFoundError) as e:
        v.add("AGENT_MEMORY.json valid JSON", False, str(e))

    # === CHECK 11: Python dependencies ===
    print("\n--- Python Dependencies ---")
    rc, _, _ = run_cmd("python3 -c 'import requests, pandas, psutil, flask, matplotlib; print(\"OK\")'")
    v.add("Python packages", rc == 0)

    print("\n--- GCP Python Clients ---")
    rc, _, _ = run_cmd("python3 -c 'import google.cloud.monitoring_v3, googleapiclient.discovery, google.auth; print(\"OK\")'")
    v.add("GCP Python clients", rc == 0)

    # === CHECK 12: Cloud readiness (optional) ===
    if not args.skip_cloud:
        print("\n--- Cloud Readiness ---")
        v.add("Cloud scripts exist",
               all(os.path.isfile(os.path.join(PROJECT_DIR, f"scripts/cloud/{s}"))
                   for s in ["setup_gcp_instance.sh", "run_cloud_workload.sh",
                              "fetch_gcp_energy.py", "teardown_gcp_instance.sh"]))
        rc, _, _ = run_cmd("gcloud config get-value project")
        v.add("GCP project configured", rc == 0)

        with open(os.path.join(PROJECT_DIR, "scripts/cloud/run_cloud_workload.sh")) as f:
            rcw_tmp = f.read()
            v.add("run_cloud_workload DOES NOT teardown",
                  "teardown_gcp_instance.sh" not in rcw_tmp)

    # === CHECK 13: Machine B (dedicated client) integration ===
    print("\n--- Machine B Dedicated Client ---")

    # Read Machine B config from AGENT_MEMORY.json
    try:
        with open(MEMORY_FILE) as f:
            mem_b = json.load(f)
        env_b       = mem_b.get("environment", {})
        client_ip   = env_b.get("client_machine_ip", "")
        client_user = env_b.get("client_machine_user", "")
        ssh_key     = env_b.get("client_machine_ssh_key", "")
        v.add("AGENT_MEMORY has client_machine_ip",    bool(client_ip))
        v.add("AGENT_MEMORY client_machine_ready",     env_b.get("client_machine_ready", False))
    except Exception as e:
        v.add("AGENT_MEMORY has client_machine_ip", False, str(e))
        v.add("AGENT_MEMORY client_machine_ready",  False, str(e))
        client_ip = client_user = ssh_key = ""

    # SSH reachability
    if client_ip and ssh_key:
        rc, out, _ = run_cmd(
            f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "
            f"-i {ssh_key} {client_user}@{client_ip} 'echo OK'",
            timeout=15
        )
        machine_b_up = rc == 0 and "OK" in out
        v.add("Machine B reachable via SSH", machine_b_up,
              f"{client_user}@{client_ip}" if machine_b_up else "SSH failed")
    else:
        machine_b_up = False
        v.add("Machine B reachable via SSH", False, "client_machine_ip/ssh_key not configured")

    # Required files on Machine B
    if machine_b_up:
        for fname in ["client_daemon.sh", "measure_client_energy.py",
                      "parse_scaphandre.py", "parse_powerstat.py"]:
            rc, out, _ = run_cmd(
                f"ssh -o StrictHostKeyChecking=no -i {ssh_key} "
                f"{client_user}@{client_ip} "
                f"'test -f ~/edge_cloud_study/{fname} && echo OK'",
                timeout=10
            )
            v.add(f"Machine B has {fname}", rc == 0 and "OK" in out)

        # Measurement tool available on Machine B
        rc, out, _ = run_cmd(
            f"ssh -o StrictHostKeyChecking=no -i {ssh_key} "
            f"{client_user}@{client_ip} "
            f"'scaphandre --version 2>/dev/null || powerstat -h 2>&1 | head -1'",
            timeout=10
        )
        v.add("Machine B measurement tool available", rc == 0 and bool(out.strip()))
    else:
        for fname in ["client_daemon.sh", "measure_client_energy.py",
                      "parse_scaphandre.py", "parse_powerstat.py"]:
            v.add(f"Machine B has {fname}", False, "Machine B unreachable")
        v.add("Machine B measurement tool available", False, "Machine B unreachable")

    # Script-level checks: FIFO removed, SSH pattern present, new edge flow
    print("\n--- Client-side Script Checks ---")

    with open(os.path.join(PROJECT_DIR, "scripts/edge/run_workload.sh")) as f:
        rw = f.read()
        v.add("run_workload.sh no FIFO references",
              "mkfifo" not in rw and "FIFO_IN" not in rw)
        v.add("run_workload.sh uses client_daemon.sh start",
              "client_daemon.sh start" in rw)
        v.add("run_workload.sh uses client_daemon.sh stop",
              "client_daemon.sh stop" in rw)
        v.add("run_workload.sh calls start_edge_server.sh",
              "start_edge_server.sh" in rw)
        v.add("run_workload.sh calls stop_edge_server.sh",
              "stop_edge_server.sh" in rw)
        v.add("run_workload.sh iperf3 from Machine B via SSH",
              "SSH_CLIENT" in rw and "iperf3" in rw and "EDGE_SERVER_IP" in rw)
        v.add("run_workload.sh no dept1 container client",
              "dept1" not in rw and "python3 \"$TOPOLOGY_SCRIPT\"" not in rw)

    # Verify setup_client_machine.sh is valid bash (not JSON error)
    setup_sh = os.path.join(PROJECT_DIR, "scripts/utils/setup_client_machine.sh")
    if os.path.isfile(setup_sh):
        with open(setup_sh) as f:
            setup_content = f.read()
        is_bash = setup_content.startswith("#!/bin/bash") or "#!/bin/bash" in setup_content[:20]
        is_json_error = '"message"' in setup_content[:100] and "Bad credentials" in setup_content
        v.add("setup_client_machine.sh is valid bash (not JSON error)",
              is_bash and not is_json_error,
              "Valid bash script" if (is_bash and not is_json_error) else "Contains JSON error or not bash")
    else:
        v.add("setup_client_machine.sh is valid bash (not JSON error)",
              False, "File not found")

    # Verify iperf3 on Machine B
    if machine_b_up:
        rc, out, _ = run_cmd(
            f"ssh -o StrictHostKeyChecking=no -i {ssh_key} "
            f"{client_user}@{client_ip} 'which iperf3'",
            timeout=10
        )
        v.add("Machine B has iperf3 installed",
              rc == 0 and "iperf3" in out,
              out.strip() if rc == 0 else "iperf3 not found")
    else:
        v.add("Machine B has iperf3 installed", False, "Machine B unreachable")

    if not args.skip_cloud:
        with open(os.path.join(PROJECT_DIR, "scripts/cloud/run_cloud_workload.sh")) as f:
            rcw = f.read()
            v.add("run_cloud_workload.sh no FIFO references",
                  "mkfifo" not in rcw and "FIFO_IN" not in rcw)
            v.add("run_cloud_workload iperf3 from Machine B via SSH",
                  "CLIENT_IP" in rcw and "iperf3" in rcw and "SSH_CLIENT" in rcw)
            v.add("run_cloud_workload.sh restarts iperf3", "pkill iperf3" in rcw)
            v.add("run_cloud_workload.sh logs boundaries", "workload_boundaries.log" in rcw)

    with open(os.path.join(PROJECT_DIR, "scripts/analysis/compare_client_energy.py")) as f:
        cce = f.read()
        v.add("compare_client_energy queries both envs",
              "edge" in cce and "cloud" in cce and "client_energy_runs" in cce)

    with open(os.path.join(PROJECT_DIR, "scripts/run_experiment.py")) as f:
        re_src = f.read()
        v.add("run_experiment calls capture_client_baseline", "capture_client_baseline.sh" in re_src)
        v.add("run_experiment calls compare_client_energy",   "compare_client_energy.py"   in re_src)
        v.add("run_experiment has Machine B pre-flight check","check_machine_b"             in re_src)

    with open(os.path.join(PROJECT_DIR, "scripts/cloud/fetch_gcp_energy.py")) as f:
        fge = f.read()
        v.add("fetch_gcp_energy appends GCP data", "df['Cloud_Server_GCP']" in fge)

    # Single-instance lifecycle checks (previously in cloud section, kept here)
    if not args.skip_cloud:
        print("\n--- Single-Instance Lifecycle Checks ---")
        with open(os.path.join(PROJECT_DIR, "scripts/cloud/teardown_gcp_instance.sh")) as f:
            td = f.read()
            v.add("teardown checks workloads_pending", "workloads_pending" in td)
            v.add("teardown has --force flag",         "--force" in td)

        with open(os.path.join(PROJECT_DIR, "scripts/run_experiment.py")) as f:
            re_src2 = f.read()
            v.add("run_experiment checks instance null at start",
                  "cloud_droplet_ready" in re_src2 and "No GCP instance is running" in re_src2)
            v.add("run_experiment summary block present",
                  "ALL WORKLOAD BATCHES COMPLETE" in re_src2)

        with open(os.path.join(PROJECT_DIR, "scripts/cloud/fetch_gcp_energy.py")) as f:
            fge2 = f.read()
            v.add("fetch_gcp_energy has proportional logic", "share_percent" in fge2)

        cur.execute("PRAGMA table_info(cloud_reported_energy)")
        cols = [r[1] for r in cur.fetchall()]
        v.add("cloud_reported_energy has attribution_method", "attribution_method" in cols)

    # === FINAL SUMMARY ===
    total, passed, failed = v.summary()
    print("\n" + "=" * 60)
    print(f"  VALIDATION SUMMARY")
    print(f"  Total: {total}  |  Passed: {passed}  |  Failed: {failed}")
    print(f"  Result: {'✅ ALL CHECKS PASSED' if failed == 0 else '❌ SOME CHECKS FAILED'}")
    print("=" * 60)

    if failed > 0:
        print("\nFailed checks:")
        for c in v.checks:
            if c["status"] == "FAIL":
                print(f"  ❌ {c['name']}: {c['message']}")

    # Save validation result to memory
    try:
        with open(MEMORY_FILE) as f:
            mem = json.load(f)
        mem["notes"].append(
            f"Pipeline validation at {datetime.now().isoformat()}: "
            f"{passed}/{total} passed, {failed} failed"
        )
        mem["last_updated"] = datetime.now().isoformat()
        with open(MEMORY_FILE, "w") as f:
            json.dump(mem, f, indent=2)
    except Exception:
        pass

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
