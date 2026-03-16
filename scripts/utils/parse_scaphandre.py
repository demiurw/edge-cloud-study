#!/usr/bin/env python3
"""
Scaphandre JSON Output Parser
==============================
Reads Scaphandre JSON output and extracts energy consumption data.
Filters for specific process energy readings and returns total Joules.

Usage:
    python3 parse_scaphandre.py <json_file> [--process iperf3]
"""

import json
import sys
import argparse


def parse_scaphandre_json(filepath, process_filter=None):
    """
    Parse Scaphandre JSON output and compute total energy in Joules.
    
    Scaphandre reports power in microwatts (uW).
    Conversion: W = uW / 1,000,000
    Energy (J) = W × duration_seconds
    
    Returns dict with:
        - total_joules: total energy consumed
        - avg_watts: average power draw
        - duration_seconds: measurement duration
        - readings_count: number of data points
        - process_joules: energy for filtered process (if applicable)
    """
    readings = []
    process_readings = []
    
    # Scaphandre can output in different formats depending on the exporter
    # Handle both single JSON and JSONL (one JSON object per line)
    try:
        with open(filepath, 'r') as f:
            content = f.read().strip()
            
        # Try parsing as a single JSON array/object first
        try:
            data = json.loads(content)
            if isinstance(data, list):
                readings = data
            else:
                readings = [data]
        except json.JSONDecodeError:
            # Try JSONL format (one JSON object per line)
            for line in content.split('\n'):
                line = line.strip()
                if line:
                    try:
                        readings.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
    except FileNotFoundError:
        print(f"ERROR: File not found: {filepath}", file=sys.stderr)
        return None
    
    if not readings:
        print("WARNING: No valid readings found in Scaphandre output", file=sys.stderr)
        return {
            "total_joules": 0,
            "avg_watts": 0,
            "duration_seconds": 0,
            "readings_count": 0,
            "process_joules": 0,
        }
    
    total_power_uw = 0
    process_power_uw = 0
    timestamps = []
    reading_count = 0
    
    for reading in readings:
        # Extract host-level power (microwatts)
        host_power = 0
        
        # Handle different Scaphandre JSON structures
        if "host" in reading:
            # Standard Scaphandre JSON exporter format
            host_power = reading["host"].get("consumption", 0)  # in uW
            timestamp = reading["host"].get("timestamp", reading.get("timestamp", 0))
            timestamps.append(timestamp)
            
            # Process-level filtering
            if process_filter and "consumers" in reading:
                for consumer in reading["consumers"]:
                    exe = consumer.get("exe", "")
                    cmdline = consumer.get("cmdline", "")
                    if process_filter.lower() in exe.lower() or process_filter.lower() in cmdline.lower():
                        process_power_uw += consumer.get("consumption", 0)
        
        elif "consumption" in reading:
            # Simplified format
            host_power = reading.get("consumption", 0)
        
        elif "power" in reading:
            # Alternative key name
            host_power = reading.get("power", 0)
        
        total_power_uw += host_power
        reading_count += 1
    
    # Calculate duration from timestamps or assume 1-second intervals
    if len(timestamps) >= 2:
        # Timestamps might be in seconds or milliseconds
        ts_sorted = sorted(timestamps)
        duration = ts_sorted[-1] - ts_sorted[0]
        if duration > 1e10:  # Likely nanoseconds
            duration = duration / 1e9
        elif duration > 1e6:  # Likely milliseconds
            duration = duration / 1e3
    else:
        # Assume 1-second intervals between readings
        duration = max(reading_count - 1, 1)
    
    # Convert microwatts to watts
    avg_power_w = (total_power_uw / reading_count) / 1_000_000 if reading_count > 0 else 0
    process_avg_w = (process_power_uw / reading_count) / 1_000_000 if reading_count > 0 else 0
    
    # Energy = Power × Time
    total_joules = avg_power_w * duration
    process_joules = process_avg_w * duration
    
    result = {
        "total_joules": round(total_joules, 6),
        "avg_watts": round(avg_power_w, 6),
        "duration_seconds": round(duration, 3),
        "readings_count": reading_count,
        "process_joules": round(process_joules, 6),
    }
    
    return result


def main():
    parser = argparse.ArgumentParser(description="Parse Scaphandre JSON output")
    parser.add_argument("json_file", help="Path to Scaphandre JSON output file")
    parser.add_argument("--process", default=None,
                        help="Filter for specific process name (e.g., iperf3)")
    parser.add_argument("--json-output", action="store_true",
                        help="Output results as JSON instead of human-readable")
    args = parser.parse_args()
    
    result = parse_scaphandre_json(args.json_file, process_filter=args.process)
    
    if result is None:
        sys.exit(1)
    
    if args.json_output:
        print(json.dumps(result, indent=2))
    else:
        print(f"Scaphandre Energy Report")
        print(f"========================")
        print(f"File:             {args.json_file}")
        print(f"Readings:         {result['readings_count']}")
        print(f"Duration:         {result['duration_seconds']:.1f} seconds")
        print(f"Avg Power:        {result['avg_watts']:.4f} W")
        print(f"Total Energy:     {result['total_joules']:.4f} J")
        if args.process:
            print(f"Process ({args.process}):  {result['process_joules']:.4f} J")


if __name__ == "__main__":
    main()
