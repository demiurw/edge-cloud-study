#!/usr/bin/env python3
"""
Compare Edge vs Cloud Results
===============================
Queries both edge_runs and cloud_reported_energy tables to generate
comparison metrics for a given workload type.

Usage:
    python3 compare_results.py --workload file_transfer [--session-id <id>]
"""

import argparse
import json
import sqlite3
import sys
import statistics

PROJECT_DIR = "/home/dem/major_project/edge_cloud_study"
DB_PATH = f"{PROJECT_DIR}/data/results.db"
EXPORTS_DIR = f"{PROJECT_DIR}/exports"


def main():
    parser = argparse.ArgumentParser(description="Compare Edge vs Cloud results")
    parser.add_argument("--workload", required=True)
    parser.add_argument("--session-id", default=None, help="Filter by session (optional)")
    args = parser.parse_args()

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    # --- Edge data ---
    edge_query = "SELECT * FROM edge_runs WHERE workload_type = ?"
    edge_params = [args.workload]
    if args.session_id:
        edge_query += " AND session_id = ?"
        edge_params.append(args.session_id)

    edge_rows = conn.execute(edge_query, edge_params).fetchall()

    # --- Cloud data ---
    cloud_query = "SELECT * FROM cloud_reported_energy WHERE workload_type = ?"
    cloud_params = [args.workload]
    if args.session_id:
        cloud_query += " AND session_id = ?"
        cloud_params.append(args.session_id)

    cloud_rows = conn.execute(cloud_query, cloud_params).fetchall()
    conn.close()

    if not edge_rows and not cloud_rows:
        print(f"No data found for workload: {args.workload}")
        sys.exit(1)

    # --- Edge metrics ---
    if edge_rows:
        edge_durations = [r["duration_seconds"] for r in edge_rows if r["duration_seconds"]]
        edge_scaph = [r["scaphandre_joules"] for r in edge_rows if r["scaphandre_joules"]]
        edge_pstat = [r["powerstat_joules"] for r in edge_rows if r["powerstat_joules"]]
        edge_data_mb = [r["data_sent_mb"] for r in edge_rows if r["data_sent_mb"]]

        edge_total_j = sum(edge_scaph)
        edge_total_data_gb = sum(edge_data_mb) / 1024
        edge_total_time = sum(edge_durations)

        print(f"\n{'='*70}")
        print(f"  EDGE RESULTS: {args.workload}")
        print(f"{'='*70}")
        print(f"  Total Runs:          {len(edge_rows)}")
        print(f"  Total Energy:        {edge_total_j:.2f} J (Scaphandre)")
        print(f"  Total Data:          {edge_total_data_gb:.4f} GB")
        print(f"  Energy/Request:      {edge_total_j/len(edge_rows):.6f} J")
        print(f"  Energy/GB:           {edge_total_j/edge_total_data_gb:.2f} J" if edge_total_data_gb > 0 else "  Energy/GB:           N/A")
        print(f"  Avg Power:           {edge_total_j/edge_total_time:.4f} W" if edge_total_time > 0 else "  Avg Power:           N/A")
        print(f"  Avg Duration:        {statistics.mean(edge_durations):.4f} s")
        if len(edge_scaph) > 1:
            print(f"  Std Dev (J/run):     {statistics.stdev(edge_scaph):.6f} J")

    # --- Cloud metrics ---
    if cloud_rows:
        latest = cloud_rows[-1]
        
        if latest["awaiting_api_data"] == 1:
            print("\n  >> WARNING: GCP energy data not yet available for this session. <<")
            print("  >> Comparison will use operational metrics only until fetch_mode is run. <<")
            
        print(f"\n{'='*70}")
        print(f"  CLOUD RESULTS: {args.workload}")
        print(f"{'='*70}")
        print(f"  Data Source:         {latest['data_source']}")
        print(f"  Model Version:       {latest.get('carbon_model_version', 'Pending')}")
        
        if latest["awaiting_api_data"] == 0:
            print(f"  Total Energy:        {latest['derived_joules']:.2f} J")
            print(f"  Carbon Footprint:    {latest['gross_carbon_gco2e']:.2f} gCO2e")
        else:
            print(f"  Total Energy:        [PENDING GCP API]")
            print(f"  Carbon Footprint:    [PENDING GCP API]")
            
        print(f"  Project:             {latest['gcp_project_id']}")
        print(f"  Region:              {latest['gcp_region']}")

    print(f"\n{'='*70}")


if __name__ == "__main__":
    main()
