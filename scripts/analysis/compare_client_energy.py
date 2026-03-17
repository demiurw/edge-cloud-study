#!/usr/bin/env python3
"""
compare_client_energy.py — Primary Analysis Tool for Client-Side Energy
=============================================================================
Computes aggregate metrics from client_energy_runs for both edge and cloud,
and outputs the primary symmetric comparison table.

Usage:
    python3 scripts/analysis/compare_client_energy.py --workload <type>
"""

import argparse
import os
import sqlite3
import pandas as pd
import numpy as np
import sys

PROJECT_DIR = "/home/dem/major_project/edge_cloud_study"
DB_PATH = f"{PROJECT_DIR}/data/results.db"
EXPORTS_DIR = f"{PROJECT_DIR}/exports"

def get_metrics(workload_type, environment):
    conn = sqlite3.connect(DB_PATH)
    query = f"""
        SELECT 
            duration_seconds,
            data_sent_mb,
            client_scaphandre_joules,
            client_powerstat_joules,
            client_cpu_avg_percent,
            response_time_ms,
            run_number
        FROM client_energy_runs 
        WHERE workload_type = ? AND environment = ?
    """
    df = pd.read_sql_query(query, conn, params=(workload_type, environment))
    conn.close()

    if df.empty:
        return None

    # Calculate metrics per run
    # J per request = total joules per run (assume 1 workload iteration = 1 request for this scope)
    # To be extremely accurate, for DB query or web request, a "run" is a batch of requests.
    # Calculate metrics per session and then aggregate
    df['runs'] = np.maximum(df['run_number'], 1)  # avoid division by zero
    df['j_per_run'] = df['client_scaphandre_joules'] / df['runs']
    df['gb'] = df['data_sent_mb'] / 1024.0
    df['j_per_gb'] = np.where(df['gb'] > 0, df['client_scaphandre_joules'] / df['gb'], 0)
    df['watts'] = np.where(df['duration_seconds'] > 0, df['client_scaphandre_joules'] / df['duration_seconds'], 0)

    total_runs = df['runs'].sum()
    total_j = df['client_scaphandre_joules'].sum()

    stats = {
        'runs': total_runs,
        'total_joules': total_j,
        'mean_j_per_run': total_j / total_runs if total_runs > 0 else 0,
        'mean_j_per_gb': total_j / df['gb'].sum() if df['gb'].sum() > 0 else 0,
        'mean_watts': df['watts'].mean(),
        'std_dev_j': df['j_per_run'].std() if len(df) > 1 else 0,
        'mean_response_ms': df['response_time_ms'].mean() if not df['response_time_ms'].isnull().all() else 0,
        'mean_cpu': df['client_cpu_avg_percent'].mean()
    }
    
    return stats

def main():
    parser = argparse.ArgumentParser(description="Analyze and compare client-side energy")
    parser.add_argument("--workload", required=True, help="Type of workload to analyze")
    args = parser.parse_args()

    workload = args.workload
    os.makedirs(EXPORTS_DIR, exist_ok=True)

    edge_stats = get_metrics(workload, "edge")
    cloud_stats = get_metrics(workload, "cloud")

    # Handle missing data gracefully
    if not edge_stats and not cloud_stats:
        print(f"No client energy data found for workload: {workload}")
        return

    def fmt(val, unit="", decimals=2):
        if val is None or pd.isna(val) or val == 0 and unit != "W avg":
            return "N/A"
        return f"{val:.{decimals}f} {unit}".strip()

    edge_j_req = fmt(edge_stats['mean_j_per_run'], "J") if edge_stats else "N/A"
    edge_j_gb = fmt(edge_stats['mean_j_per_gb'], "J") if edge_stats else "N/A"
    edge_watts = fmt(edge_stats['mean_watts'], "W avg") if edge_stats else "N/A"
    edge_total = fmt(edge_stats['total_joules'], "J") if edge_stats else "N/A"
    edge_std = fmt(edge_stats['std_dev_j'], "J") if edge_stats else "N/A"
    edge_rt = fmt(edge_stats['mean_response_ms'], "ms") if edge_stats else "N/A"

    cloud_j_req = fmt(cloud_stats['mean_j_per_run'], "J") if cloud_stats else "N/A"
    cloud_j_gb = fmt(cloud_stats['mean_j_per_gb'], "J") if cloud_stats else "N/A"
    cloud_watts = fmt(cloud_stats['mean_watts'], "W avg") if cloud_stats else "N/A"
    cloud_total = fmt(cloud_stats['total_joules'], "J") if cloud_stats else "N/A"
    cloud_std = fmt(cloud_stats['std_dev_j'], "J") if cloud_stats else "N/A"
    cloud_rt = fmt(cloud_stats['mean_response_ms'], "ms") if cloud_stats else "N/A"

    # Identify most efficient
    more_efficient = "Unknown"
    difference_str = "N/A"
    
    if edge_stats and cloud_stats:
        edge_j = edge_stats['mean_j_per_run']
        cloud_j = cloud_stats['mean_j_per_run']
        if edge_j > 0 and cloud_j > 0:
            if edge_j < cloud_j:
                more_efficient = "Edge"
                diff = ((cloud_j - edge_j) / cloud_j) * 100
                difference_str = f"{diff:.1f}% lower on Edge"
            else:
                more_efficient = "Cloud"
                diff = ((edge_j - cloud_j) / edge_j) * 100
                difference_str = f"{diff:.1f}% lower on Cloud"

    print(f"")
    print(f"  ╔══════════════════════════════════════════════════════════════════╗")
    print(f"  ║         CLIENT-SIDE ENERGY COMPARISON — {workload.ljust(24)} ║")
    print(f"  ╠══════════════════════╦═══════════════════╦═══════════════════════╣")
    print(f"  ║ Metric               ║ Edge (measured)   ║ Cloud (measured)      ║")
    print(f"  ╠══════════════════════╬═══════════════════╬═══════════════════════╣")
    print(f"  ║ J per run            ║ {edge_j_req.ljust(17)} ║ {cloud_j_req.ljust(21)} ║")
    print(f"  ║ J per GB             ║ {edge_j_gb.ljust(17)} ║ {cloud_j_gb.ljust(21)} ║")
    print(f"  ║ J per second         ║ {edge_watts.ljust(17)} ║ {cloud_watts.ljust(21)} ║")
    print(f"  ║ Total J              ║ {edge_total.ljust(17)} ║ {cloud_total.ljust(21)} ║")
    print(f"  ║ Std deviation        ║ {edge_std.ljust(17)} ║ {cloud_std.ljust(21)} ║")
    print(f"  ║ Mean response time   ║ {edge_rt.ljust(17)} ║ {cloud_rt.ljust(21)} ║")
    print(f"  ║ Measurement type     ║ Measured          ║ Measured              ║")
    print(f"  ╚══════════════════════╩═══════════════════╩═══════════════════════╝")
    print(f"")
    print(f"  More efficient environment: {more_efficient}")
    print(f"  Energy difference: {difference_str}")
    print(f"")
    print(f"  *Note: Cloud SERVER-SIDE energy is pending GCP Carbon Footprint API data.")
    print(f"         It will be appended to exports/comparison_client_{workload}.csv when available.")
    print(f"")

    # Export to CSV
    csv_path = f"{EXPORTS_DIR}/comparison_client_{workload}.csv"
    with open(csv_path, "w") as f:
        f.write("Metric,Edge_Client_Measured,Cloud_Client_Measured\n")
        f.write(f"J_per_run,{edge_stats['mean_j_per_run'] if edge_stats else ''},{cloud_stats['mean_j_per_run'] if cloud_stats else ''}\n")
        f.write(f"J_per_GB,{edge_stats['mean_j_per_gb'] if edge_stats else ''},{cloud_stats['mean_j_per_gb'] if cloud_stats else ''}\n")
        f.write(f"Watts_avg,{edge_stats['mean_watts'] if edge_stats else ''},{cloud_stats['mean_watts'] if cloud_stats else ''}\n")
        f.write(f"Total_J,{edge_stats['total_joules'] if edge_stats else ''},{cloud_stats['total_joules'] if cloud_stats else ''}\n")
        f.write(f"Std_Dev_J,{edge_stats['std_dev_j'] if edge_stats else ''},{cloud_stats['std_dev_j'] if cloud_stats else ''}\n")
        f.write(f"Response_Time_ms,{edge_stats['mean_response_ms'] if edge_stats else ''},{cloud_stats['mean_response_ms'] if cloud_stats else ''}\n")
    
    print(f"  Exported tabular data to: {csv_path}")


if __name__ == "__main__":
    main()
