#!/usr/bin/env python3
"""
Master Experiment Orchestration Script
========================================
Coordinates the full Cloud vs Edge energy measurement pipeline.
Reads AGENT_MEMORY.json on startup, guides user through checkpoints,
and runs the appropriate sub-scripts.

Usage:
    python3 run_experiment.py --environment edge --workload file_transfer \
        --size small --runs 1000 --session-id session_001
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime

PROJECT_DIR = "/home/dem/major_project/edge_cloud_study"
MEMORY_FILE = f"{PROJECT_DIR}/AGENT_MEMORY.json"
DB_PATH = f"{PROJECT_DIR}/data/results.db"
SCRIPTS_EDGE = f"{PROJECT_DIR}/scripts/edge"
SCRIPTS_CLOUD = f"{PROJECT_DIR}/scripts/cloud"
EXPORTS_DIR = f"{PROJECT_DIR}/exports"


def load_memory():
    """Load AGENT_MEMORY.json."""
    try:
        with open(MEMORY_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        print("WARNING: AGENT_MEMORY.json not found. Using defaults.")
        return {}


def save_memory(mem):
    """Save AGENT_MEMORY.json."""
    mem["last_updated"] = datetime.now().isoformat()
    with open(MEMORY_FILE, "w") as f:
        json.dump(mem, f, indent=2)


def confirm(prompt):
    """Ask user for confirmation."""
    response = input(f"\n{prompt} [y/N]: ").strip().lower()
    return response == 'y'


def run_script(cmd, description):
    """Run a shell command and display output."""
    print(f"\n{'='*60}")
    print(f"  {description}")
    print(f"{'='*60}")
    result = subprocess.run(cmd, shell=True)
    if result.returncode != 0:
        print(f"ERROR: {description} failed (exit code {result.returncode})")
        return False
    return True


def generate_comparison(session_id, workload_type):
    """Generate a comparison summary between edge and cloud results."""
    # We offload this to the dedicated comparison script now
    print("\nGenerating comparison...")
    run_script(
        f"python3 {PROJECT_DIR}/scripts/analysis/compare_results.py "
        f"--workload {workload_type} --session-id {session_id}",
        "Comparison Summary"
    )
    
    # Also generate the CSV manually here for backward compatibility
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    # Edge metrics
    cur.execute("""
        SELECT COUNT(*) as runs,
               AVG(duration_seconds) as avg_duration,
               AVG(scaphandre_joules) as avg_scaph_j,
               AVG(powerstat_joules) as avg_pstat_j,
               SUM(scaphandre_joules) as total_scaph_j,
               SUM(powerstat_joules) as total_pstat_j,
               AVG(data_sent_mb) as avg_data_mb,
               SUM(data_sent_mb) as total_data_mb
        FROM edge_runs WHERE session_id = ? AND workload_type = ?
    """, (session_id, workload_type))
    edge = dict(cur.fetchone() or {})
    
    # Cloud metrics
    cur.execute("""
        SELECT derived_joules, gross_carbon_gco2e, awaiting_api_data
        FROM cloud_reported_energy WHERE session_id = ? AND workload_type = ?
        ORDER BY report_id DESC LIMIT 1
    """, (session_id, workload_type))
    cloud_row = cur.fetchone()
    cloud = dict(cloud_row) if cloud_row else {}
    conn.close()

    csv_path = f"{EXPORTS_DIR}/comparison_{workload_type}_{session_id}.csv"
    with open(csv_path, "w") as f:
        f.write("Metric,Edge,Cloud\n")
        
        edge_runs = edge.get("runs", 0) or 0
        edge_total_j = edge.get("total_scaph_j", 0) or 0
        f.write(f"Total Runs,{edge_runs},N/A\n")
        f.write(f"Total Energy (J),{edge_total_j:.2f},{cloud.get('derived_joules', 'PENDING')}\n")
        if cloud.get('gross_carbon_gco2e') is not None:
             f.write(f"Carbon (gCO2e),N/A,{cloud.get('gross_carbon_gco2e')}\n")

    print(f"\nComparison exported to: {csv_path}")
    return csv_path


def parse_args():
    parser = argparse.ArgumentParser(description="Master Experiment Runner")
    parser.add_argument("--environment", choices=["edge", "cloud", "both"])
    parser.add_argument("--workload", 
                        choices=["file_transfer", "video_encoding", "db_query", "web_request"])
    parser.add_argument("--size", default="small", choices=["small", "medium", "large"])
    parser.add_argument("--runs", type=int, default=1000)
    parser.add_argument("--session-id", default=None)
    parser.add_argument("--cloud-mode", choices=["run_mode", "fetch_mode"], default="run_mode",
                        help="GCP energy mode. 'run_mode' immediately after tests, 'fetch_mode' weeks later.")
    return parser.parse_args()


def main():
    args = parse_args()
    mem = load_memory()

    print("=" * 60)
    print("  Cloud vs Edge Energy Trade-off Study")
    print("  Master Experiment Runner")
    print("=" * 60)
    print(f"  Phase:       {mem.get('phase', 'Unknown')}")
    print(f"  Last update: {mem.get('last_updated', 'Unknown')}")
    print(f"  Completed:   {len(mem.get('completed_steps', []))} steps")
    print(f"  Runs done:   {mem.get('experiment', {}).get('total_runs_completed', 0)}")
    print("=" * 60)
    
    # --- FETCH MODE SHORTCUT ---
    if getattr(args, "cloud_mode", "run_mode") == "fetch_mode":
        awaiting = mem.get("experiment", {}).get("sessions_awaiting_gcp_data", [])
        if not awaiting:
            print("No sessions awaiting GCP data.")
            sys.exit(0)
            
        print("\n>>> GCP CARBON FOOTPRINT FETCH MODE <<<")
        org_id = input("Enter your GCP Organization ID: ").strip()
        if not org_id:
            print("ERROR: Org ID required to query Carbon Footprint API.")
            print("Run 'gcloud organizations list' to find it.")
            sys.exit(1)
            
        run_script(
            f"python3 {SCRIPTS_CLOUD}/fetch_gcp_energy.py --mode fetch_mode --org-id {org_id}",
            "Fetching GCP Carbon Footprint Data"
        )
        
        # After fetching, regenerate comparisons for now-completed sessions
        # (Simplified loop here; a real tool might query DB to find which workloads matched which session)
        mem = load_memory() 
        completed = mem.get("experiment", {}).get("sessions_with_gcp_data", [])
        if completed:
            print("\nUpdating comparison reports for completed sessions...")
            for sid in completed:
                # Use a default workload since we might not know it here
                run_script(
                    f"python3 {PROJECT_DIR}/scripts/analysis/compare_results.py --workload file_transfer --session-id {sid}",
                    f"Comparison Summary for {sid}"
                )
        sys.exit(0)

    # Regular validation
    if not args.environment or not args.workload or not args.session_id:
        print("ERROR: --environment, --workload, and --session-id required for run_mode")
        sys.exit(1)

    # Register session
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        INSERT OR IGNORE INTO sessions (session_id, created_at, workload_type, environment, status)
        VALUES (?, ?, ?, ?, 'active')
    """, (args.session_id, datetime.now().isoformat(), args.workload, args.environment))
    conn.commit()
    conn.close()

    # === EDGE RUNS ===
    if args.environment in ("edge", "both"):
        print("\n>>> EDGE ENVIRONMENT <<<")

        # Step 1: Baseline
        if not confirm("Capture baseline energy measurements?"):
            print("Skipping baseline.")
        else:
            run_script(
                f"sudo bash {SCRIPTS_EDGE}/capture_baseline.sh "
                f"--session-id {args.session_id} --workload-type {args.workload}",
                "Capturing Edge Baseline"
            )

            # Show baseline
            conn = sqlite3.connect(DB_PATH)
            row = conn.execute(
                "SELECT * FROM edge_baselines WHERE session_id=? ORDER BY baseline_id DESC LIMIT 1",
                (args.session_id,)
            ).fetchone()
            conn.close()
            if row:
                print(f"\nBaseline: PowerStat={row[5]}W, Scaphandre={row[4]}W, CPU={row[6]}%")

            if not confirm("Baseline looks good. Proceed with workload runs?"):
                print("Stopping at baseline checkpoint.")
                return

        # Step 2: Run workload
        run_script(
            f"sudo bash {SCRIPTS_EDGE}/run_workload.sh "
            f"--session-id {args.session_id} --workload {args.workload} "
            f"--size {args.size} --runs {args.runs}",
            f"Running Edge {args.workload} ({args.runs} runs)"
        )

        # Update memory
        mem = load_memory()
        exp = mem.setdefault("experiment", {})
        exp["total_runs_completed"] = exp.get("total_runs_completed", 0) + args.runs
        exp["last_run_id"] = args.session_id
        if args.workload not in exp.get("workloads_completed", []):
            exp.setdefault("workloads_completed", []).append(args.workload)
        save_memory(mem)

        print("\nEdge runs complete!")
        if args.environment == "edge" and not confirm("Continue to comparison summary?"):
            return

    # === CLOUD RUNS ===
    if args.environment in ("cloud", "both"):
        print("\n>>> CLOUD ENVIRONMENT (GCP) <<<")

        gcp_project = mem.get("environment", {}).get("gcp_project_id")
        gcp_region = mem.get("environment", {}).get("gcp_region")
        instance_ip = mem.get("environment", {}).get("gcp_instance_ip")
        instance_id = mem.get("environment", {}).get("gcp_instance_id")
        zone = "us-central1-a" # default assumption

        if not gcp_project or not gcp_region:
            print("ERROR: GCP Project ID or Region not set in AGENT_MEMORY.json.")
            return

        # Check if instance exists
        if not mem.get("environment", {}).get("cloud_droplet_ready"):
            print("\n" + "!" * 60)
            print("  No GCP instance is running.")
            print("  Run setup_gcp_instance.sh first, or press Enter to run it now.")
            print("!" * 60)
            if not confirm(f"Provision a new GCP e2-micro instance in {gcp_region} now?"):
                print("Skipping cloud setup. Please provision an instance.")
                return
            run_script(
                f"bash {SCRIPTS_CLOUD}/setup_gcp_instance.sh "
                f"--project-id {gcp_project} --region {gcp_region} "
                f"--zone {zone} --session-id {args.session_id}",
                "Setting up GCP Instance"
            )
            mem = load_memory()
            instance_ip = mem.get("environment", {}).get("gcp_instance_ip")
            instance_id = mem.get("environment", {}).get("gcp_instance_id")

        if not instance_ip or not instance_id:
            print("ERROR: GCP Instance IP or ID missing.")
            return

        if not confirm(f"Run cloud workload on {instance_ip}?"):
            return

        # Run cloud workload
        run_script(
            f"bash {SCRIPTS_CLOUD}/run_cloud_workload.sh "
            f"--session-id {args.session_id} --workload {args.workload} "
            f"--size {args.size} --runs {args.runs} "
            f"--instance-ip {instance_ip} --project-id {gcp_project} "
            f"--instance-id {instance_id}",
            f"Running Cloud {args.workload} ({args.runs} runs)"
        )

        # Log energy placeholder
        print("\nRecording session for future energy data fetch...")
        run_script(
            f"python3 {SCRIPTS_CLOUD}/fetch_gcp_energy.py --mode run_mode "
            f"--session-id {args.session_id} --workload-type {args.workload}",
            "GCP Energy Placeholder"
        )
        
        mem = load_memory()
        pending = mem.get('experiment', {}).get('sessions_awaiting_gcp_data', [])
        
        # We don't teardown per-workload in the single-instance lifecycle.
        print("\n" + "="*60)
        print("  GCP CLOUD WORKLOADS COMPLETE FOR THIS BATCH")
        print("="*60)

    # === COMPARISON ===
    if args.environment == "both":
        generate_comparison(args.session_id, args.workload)

    # Update memory
    mem = load_memory()
    mem["phase"] = "Experiment runs in progress"
    # Remove this workload from 'pending' if it was there
    workloads_pending = mem.setdefault("experiment", {}).setdefault("workloads_pending", [])
    if args.workload in workloads_pending:
        workloads_pending.remove(args.workload)

    save_memory(mem)

    print("\n" + "=" * 60)
    print("  EXPERIMENT SESSION COMPLETE")
    print("=" * 60)

    # Summarize if ALL workloads are complete
    if not workloads_pending and mem.get("environment", {}).get("cloud_droplet_ready"):
        start_time = mem.get("environment", {}).get("gcp_instance_start_time", "Unknown")
        print("\n" + "*" * 60)
        print("  ALL WORKLOAD BATCHES COMPLETE")
        print("*" * 60)
        print(f"  Instance has been running since: {start_time}")
        print("  Workload boundaries logged at: logs/cloud/workload_boundaries.log")
        print("\n  NEXT STEPS:")
        print("  1. Run teardown_gcp_instance.sh to destroy the instance and stop billing")
        print("  2. Note your GCP project billing period for Carbon Footprint API retrieval")
        print("  3. Return in 4-6 weeks and run: python3 scripts/cloud/fetch_gcp_energy.py --mode fetch_mode")
        print("*" * 60)
        
        gcp_project = mem.get("environment", {}).get("gcp_project_id")
        zone = "us-central1-a"
        if confirm("Run teardown now?"):
            run_script(
                f"bash {PROJECT_DIR}/scripts/cloud/teardown_gcp_instance.sh "
                f"--project-id {gcp_project} --zone {zone}",
                "GCP Instance Teardown"
            )


if __name__ == "__main__":
    main()
