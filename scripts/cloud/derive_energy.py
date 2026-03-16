#!/usr/bin/env python3
"""
Cloud Energy Derivation Script
================================
Applies the Cloud Carbon Footprint energy model to estimate energy
consumption from cloud workload metrics (CPU hours, bandwidth, etc.).

Based on: Masanet et al. (2020) baseline — 3.84W TDP per shared vCPU

Usage:
    python3 derive_energy.py --session-id <id> --workload-type <type> \
        [--pue 1.2] [--tdp 3.84] [--region nyc3]
"""

import argparse
import json
import sqlite3
import sys
from datetime import datetime

PROJECT_DIR = "/home/dem/major_project/edge_cloud_study"
DB_PATH = f"{PROJECT_DIR}/data/results.db"


def parse_args():
    parser = argparse.ArgumentParser(description="Derive cloud energy estimates")
    parser.add_argument("--session-id", required=True, help="Session ID to process")
    parser.add_argument("--workload-type", required=True, help="Workload type")
    parser.add_argument("--pue", type=float, default=1.2,
                        help="Power Usage Effectiveness factor (default: 1.2)")
    parser.add_argument("--tdp", type=float, default=3.84,
                        help="TDP watts per shared vCPU (default: 3.84W, Masanet 2020)")
    parser.add_argument("--region", default="nyc3",
                        help="Datacenter region (default: nyc3)")
    parser.add_argument("--energy-per-gb-wh", type=float, default=0.001,
                        help="Network energy per GB in kWh (default: 0.001)")
    parser.add_argument("--confirm", action="store_true",
                        help="Skip confirmation prompt")
    return parser.parse_args()


def main():
    args = parse_args()

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    # Fetch cloud runs
    cur.execute("""
        SELECT * FROM cloud_runs
        WHERE session_id = ? AND workload_type = ?
    """, (args.session_id, args.workload_type))
    rows = cur.fetchall()

    if not rows:
        print(f"ERROR: No cloud_runs found for session={args.session_id}, "
              f"workload={args.workload_type}")
        sys.exit(1)

    # Aggregate metrics
    total_duration_s = sum(r["duration_seconds"] for r in rows)
    total_bandwidth_bytes = sum(r["data_sent_mb"] * 1024 * 1024 for r in rows)
    total_requests = sum(r["request_count"] or 0 for r in rows)
    mean_response_ms = (sum(r["response_time_ms"] or 0 for r in rows) / len(rows)) if rows else 0
    avg_cpu = (sum(r["cpu_avg_percent"] or 0 for r in rows) / len(rows)) if rows else 0

    total_bandwidth_gb = total_bandwidth_bytes / (1024 ** 3)
    total_cpu_hours = total_duration_s / 3600.0

    # --- Energy Model ---
    # Energy (kWh) = (CPU_hours × TDP_watts × PUE) / 1000 + (bandwidth_GB × energy_per_gb_kwh)
    cpu_energy_kwh = (total_cpu_hours * args.tdp * args.pue) / 1000.0
    network_energy_kwh = total_bandwidth_gb * args.energy_per_gb_wh
    total_energy_kwh = cpu_energy_kwh + network_energy_kwh

    # Convert to Joules: 1 kWh = 3,600,000 J
    total_energy_joules = total_energy_kwh * 3_600_000

    # Per-unit calculations
    energy_per_request_j = total_energy_joules / total_requests if total_requests > 0 else 0
    energy_per_gb_j = total_energy_joules / total_bandwidth_gb if total_bandwidth_gb > 0 else 0

    # Cost estimate (DigitalOcean Basic: $0.00744/hr for s-1vcpu-1gb)
    cost_per_hour = 0.00744
    estimated_cost = total_cpu_hours * cost_per_hour

    # --- Display derivation ---
    print("=" * 60)
    print("  Cloud Energy Derivation Summary")
    print("=" * 60)
    print(f"  Session:              {args.session_id}")
    print(f"  Workload:             {args.workload_type}")
    print(f"  Total Runs:           {len(rows)}")
    print(f"  Total Duration:       {total_duration_s:.2f} s ({total_cpu_hours:.4f} CPU-hours)")
    print(f"  Total Bandwidth:      {total_bandwidth_gb:.4f} GB")
    print(f"  Total Requests:       {total_requests}")
    print(f"  Mean Response Time:   {mean_response_ms:.2f} ms")
    print()
    print("  --- Energy Model Assumptions ---")
    print(f"  TDP per vCPU:         {args.tdp} W (Masanet et al. 2020)")
    print(f"  PUE Factor:           {args.pue}")
    print(f"  Network Energy:       {args.energy_per_gb_wh} kWh/GB")
    print(f"  Region:               {args.region}")
    print()
    print("  --- Derived Energy ---")
    print(f"  CPU Energy:           {cpu_energy_kwh:.6f} kWh")
    print(f"  Network Energy:       {network_energy_kwh:.6f} kWh")
    print(f"  Total Energy:         {total_energy_kwh:.6f} kWh = {total_energy_joules:.2f} J")
    print(f"  Energy/Request:       {energy_per_request_j:.6f} J")
    print(f"  Energy/GB:            {energy_per_gb_j:.2f} J")
    print(f"  Estimated Cost:       ${estimated_cost:.4f} USD")
    print("=" * 60)

    # Confirmation
    if not args.confirm:
        response = input("\nAccept these assumptions and save? [y/N]: ").strip().lower()
        if response != 'y':
            print("Aborted. Adjust --pue and --tdp as needed.")
            sys.exit(0)

    # --- Insert into cloud_derived_energy ---
    model_desc = f"Masanet2020: TDP={args.tdp}W, PUE={args.pue}, Network={args.energy_per_gb_wh}kWh/GB"

    cur.execute("""
        INSERT INTO cloud_derived_energy (
            session_id, workload_type, total_bandwidth_gb, total_cpu_hours,
            mean_response_time_ms, total_requests, energy_model_used,
            energy_per_gb_wh, pue_factor, datacenter_region,
            estimated_total_energy_joules, estimated_energy_per_request_joules,
            estimated_energy_per_gb_joules, estimated_cost_usd,
            derivation_notes, timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        args.session_id, args.workload_type, total_bandwidth_gb, total_cpu_hours,
        mean_response_ms, total_requests, model_desc,
        args.energy_per_gb_wh, args.pue, args.region,
        total_energy_joules, energy_per_request_j,
        energy_per_gb_j, estimated_cost,
        f"Runs: {len(rows)}, Avg CPU: {avg_cpu:.1f}%",
        datetime.now().isoformat(),
    ))
    conn.commit()
    conn.close()

    print("\nDerivation saved to cloud_derived_energy table.")


if __name__ == "__main__":
    main()
