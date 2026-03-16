#!/usr/bin/env python3
"""
PowerStat Log Parser
=====================
Reads PowerStat log output and extracts power readings over time.
Integrates Power × Time to calculate total energy in Joules.

Usage:
    python3 parse_powerstat.py <log_file> [--duration <seconds>]
"""

import re
import sys
import json
import argparse


def parse_powerstat_log(filepath, duration_override=None):
    """
    Parse PowerStat log file and compute total energy in Joules.
    
    PowerStat outputs Watts at intervals (default 1 second each).
    Energy (J) = sum of (Watts × interval_duration) for each reading.
    
    Returns dict with:
        - total_joules: total energy consumed
        - avg_watts: average power draw
        - min_watts: minimum power reading
        - max_watts: maximum power reading
        - duration_seconds: total measurement duration
        - readings_count: number of valid power readings
    """
    power_readings = []
    
    try:
        with open(filepath, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"ERROR: File not found: {filepath}", file=sys.stderr)
        return None
    
    # PowerStat output formats vary by version. Common patterns:
    # "  Time    User  Nice   Sys  Idle    IO  Run Ctxt/s  IRQ/s Fork Exec  Watts"
    # Or simpler: timestamps with watt readings
    
    # Pattern 1: Standard powerstat table output
    # Look for lines with a watt reading at the end
    watts_pattern = re.compile(
        r'^\s*[\d:]+\s+'       # timestamp
        r'[\d.]+\s+'           # user CPU
        r'[\d.]+\s+'           # nice
        r'[\d.]+\s+'           # sys
        r'[\d.]+\s+'           # idle
        r'[\d.]+\s+'           # IO wait
        r'[\d.]+\s+'           # running
        r'[\d.]+\s+'           # context switches
        r'[\d.]+\s+'           # IRQs
        r'[\d.]+\s+'           # fork
        r'[\d.]+\s+'           # exec
        r'([\d.]+)\s*$'        # Watts (capture group)
    )
    
    # Pattern 2: Simpler format — just looking for numbers that could be watts
    simple_watts_pattern = re.compile(r'([\d.]+)\s*[Ww](?:atts?)?')
    
    # Pattern 3: Average line
    avg_pattern = re.compile(r'[Aa]verage\s+.*?([\d.]+)\s*$')
    
    average_watts = None
    
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#') or line.startswith('---'):
            continue
        
        # Skip header lines
        if 'Time' in line and 'Watts' in line:
            continue
        if 'Average' in line or 'average' in line:
            match = avg_pattern.match(line)
            if match:
                average_watts = float(match.group(1))
            continue
        if 'Summary' in line or 'summary' in line:
            continue
        
        # Try standard format
        match = watts_pattern.match(line)
        if match:
            watts = float(match.group(1))
            if watts > 0:  # Filter out zero readings
                power_readings.append(watts)
            continue
        
        # Try to find watts value in less structured output
        # Look for lines that end with a float that looks like a power reading
        parts = line.split()
        if len(parts) >= 2:
            try:
                last_val = float(parts[-1])
                # Sanity check: typical system power is 5-500W
                if 1.0 <= last_val <= 1000.0:
                    # Only if the line starts with something that looks like a timestamp
                    if re.match(r'^\d{2}:\d{2}:\d{2}', parts[0]):
                        power_readings.append(last_val)
            except (ValueError, IndexError):
                pass
    
    if not power_readings and average_watts:
        # If no individual readings but we have an average
        duration = duration_override or 60
        return {
            "total_joules": round(average_watts * duration, 6),
            "avg_watts": round(average_watts, 4),
            "min_watts": round(average_watts, 4),
            "max_watts": round(average_watts, 4),
            "duration_seconds": duration,
            "readings_count": 1,
        }
    
    if not power_readings:
        print("WARNING: No valid power readings found in PowerStat output", file=sys.stderr)
        return {
            "total_joules": 0,
            "avg_watts": 0,
            "min_watts": 0,
            "max_watts": 0,
            "duration_seconds": 0,
            "readings_count": 0,
        }
    
    # Assume 1-second intervals between readings (powerstat default)
    interval = 1.0
    # If duration override provided, calculate actual interval
    if duration_override and len(power_readings) > 1:
        interval = duration_override / len(power_readings)
    
    total_joules = sum(w * interval for w in power_readings)
    avg_watts = sum(power_readings) / len(power_readings)
    duration = len(power_readings) * interval
    
    # Use override duration if provided
    if duration_override:
        total_joules = avg_watts * duration_override
        duration = duration_override
    
    result = {
        "total_joules": round(total_joules, 6),
        "avg_watts": round(avg_watts, 4),
        "min_watts": round(min(power_readings), 4),
        "max_watts": round(max(power_readings), 4),
        "duration_seconds": round(duration, 3),
        "readings_count": len(power_readings),
    }
    
    return result


def main():
    parser = argparse.ArgumentParser(description="Parse PowerStat log output")
    parser.add_argument("log_file", help="Path to PowerStat log file")
    parser.add_argument("--duration", type=float, default=None,
                        help="Override measurement duration in seconds")
    parser.add_argument("--json-output", action="store_true",
                        help="Output results as JSON")
    args = parser.parse_args()
    
    # Support legacy positional duration argument
    duration = args.duration
    
    result = parse_powerstat_log(args.log_file, duration_override=duration)
    
    if result is None:
        sys.exit(1)
    
    if args.json_output:
        print(json.dumps(result, indent=2))
    else:
        print(f"PowerStat Energy Report")
        print(f"=======================")
        print(f"File:          {args.log_file}")
        print(f"Readings:      {result['readings_count']}")
        print(f"Duration:      {result['duration_seconds']:.1f} seconds")
        print(f"Avg Power:     {result['avg_watts']:.2f} W")
        print(f"Min Power:     {result['min_watts']:.2f} W")
        print(f"Max Power:     {result['max_watts']:.2f} W")
        print(f"Total Energy:  {result['total_joules']:.2f} J")


if __name__ == "__main__":
    main()
