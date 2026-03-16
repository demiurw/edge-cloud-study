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
        "scripts/edge/run_workload.sh",
        "scripts/utils/parse_scaphandre.py",
        "scripts/utils/parse_powerstat.py",
        "scripts/cloud/setup_gcp_instance.sh",
        "scripts/cloud/run_cloud_workload.sh",
        "scripts/cloud/fetch_gcp_energy.py",
        "scripts/cloud/teardown_gcp_instance.sh",
        "scripts/run_experiment.py",
        "scripts/analysis/compare_results.py",
    ]
    for f in required_files:
        path = os.path.join(PROJECT_DIR, f)
        v.add(f"File: {f}", os.path.isfile(path))

    # === CHECK 3: SQLite database tables ===
    print("\n--- Database Tables ---")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    expected_tables = ["edge_runs", "edge_baselines", "cloud_runs", "cloud_reported_energy", "sessions"]
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    existing_tables = [row[0] for row in cur.fetchall()]
    for t in expected_tables:
        v.add(f"Table: {t}", t in existing_tables)

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

    # === CHECK 8: Topology test (3 runs) ===
    print("\n--- Topology Validation (3 runs) ---")
    print("  Running topology test... (this may take 1-2 minutes)")
    run_cmd("sudo mn -c 2>/dev/null", timeout=30)

    rc, out, err = run_cmd(
        f"sudo python3 {TOPOLOGY_SCRIPT} --workload file_transfer --size small "
        f"--runs 3 --session-id {VALIDATION_SESSION}",
        timeout=300
    )
    v.add("Topology runs successfully", rc == 0,
          f"exit code {rc}" if rc != 0 else "3 runs completed")

    # Check JSONL output
    jsonl_path = f"{PROJECT_DIR}/logs/iperf3/{VALIDATION_SESSION}_file_transfer_small.jsonl"
    if os.path.isfile(jsonl_path):
        with open(jsonl_path) as f:
            lines = f.readlines()
        v.add("JSONL output created", len(lines) == 3, f"{len(lines)} entries")

        # Verify entries are valid JSON with no errors
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
                   for s in ["setup_gcp_instance.sh", "run_cloud_workload.sh", "fetch_gcp_energy.py", "teardown_gcp_instance.sh"]))
        # Note: actual cloud API check requires auth, verify gcloud is configured
        rc, _, _ = run_cmd("gcloud config get-value project")
        v.add("GCP project configured", rc == 0)

        # Single-Instance Lifecycle Checks
        print("\n--- Single-Instance Lifecycle Checks ---")
        
        with open(os.path.join(PROJECT_DIR, "scripts/cloud/teardown_gcp_instance.sh")) as f:
            td = f.read()
            v.add("teardown checks workloads_pending", "workloads_pending" in td)
            v.add("teardown has --force flag", "--force" in td)
            
        with open(os.path.join(PROJECT_DIR, "scripts/cloud/run_cloud_workload.sh")) as f:
            rcw = f.read()
            v.add("run_cloud_workload DOES NOT teardown", "teardown_gcp_instance.sh" not in rcw)
            v.add("run_cloud_workload restarts iperf3", "pkill iperf3" in rcw)
            v.add("run_cloud_workload logs boundaries", "workload_boundaries.log" in rcw)

        with open(os.path.join(PROJECT_DIR, "scripts/run_experiment.py")) as f:
            re = f.read()
            v.add("run_experiment checks instance null at start", "cloud_droplet_ready" in re and "No GCP instance is running" in re)
            v.add("run_experiment summary block present", "ALL WORKLOAD BATCHES COMPLETE" in re)

        with open(os.path.join(PROJECT_DIR, "scripts/cloud/fetch_gcp_energy.py")) as f:
            fge = f.read()
            v.add("fetch_gcp_energy has proportional logic", "share_percent" in fge)

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
