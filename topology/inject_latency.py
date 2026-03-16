#!/usr/bin/env python3
"""
Network Condition Injection Script
====================================
Adds variable latency, packet loss, or bandwidth caps to Containernet links
using tc/netem. This is an optional utility for future experiments.

Usage:
    sudo python3 inject_latency.py --interface s1-eth1 --delay 50ms --loss 1% --bandwidth 50mbit
    sudo python3 inject_latency.py --interface s1-eth1 --reset

This script is NOT run by the default topology — it is for future
experiments exploring the effect of degraded network conditions.
"""

import argparse
import subprocess
import sys


def parse_args():
    parser = argparse.ArgumentParser(description="Inject network conditions via tc/netem")
    parser.add_argument("--interface", required=True,
                        help="Network interface to modify (e.g., s1-eth1)")
    parser.add_argument("--delay", default=None,
                        help="Additional delay (e.g., 50ms, 100ms)")
    parser.add_argument("--jitter", default=None,
                        help="Delay jitter (e.g., 10ms)")
    parser.add_argument("--loss", default=None,
                        help="Packet loss percentage (e.g., 1%%, 5%%)")
    parser.add_argument("--bandwidth", default=None,
                        help="Bandwidth cap (e.g., 10mbit, 50mbit)")
    parser.add_argument("--corruption", default=None,
                        help="Packet corruption percentage (e.g., 0.1%%)")
    parser.add_argument("--duplication", default=None,
                        help="Packet duplication percentage (e.g., 1%%)")
    parser.add_argument("--reorder", default=None,
                        help="Packet reorder percentage (e.g., 5%%)")
    parser.add_argument("--reset", action="store_true",
                        help="Remove all tc rules from the interface")
    parser.add_argument("--show", action="store_true",
                        help="Show current tc rules on the interface")
    return parser.parse_args()


def run_cmd(cmd, check=True):
    """Run a shell command and return output."""
    print(f"  $ {cmd}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.stdout.strip():
        print(f"    {result.stdout.strip()}")
    if result.returncode != 0 and check:
        print(f"    ERROR: {result.stderr.strip()}")
    return result


def reset_interface(interface):
    """Remove all tc rules from an interface."""
    print(f"[*] Resetting tc rules on {interface}")
    run_cmd(f"tc qdisc del dev {interface} root 2>/dev/null", check=False)
    print(f"[+] Interface {interface} reset to defaults")


def show_rules(interface):
    """Show current tc rules on an interface."""
    print(f"[*] Current tc rules on {interface}:")
    run_cmd(f"tc qdisc show dev {interface}")
    run_cmd(f"tc class show dev {interface}")
    run_cmd(f"tc filter show dev {interface}")


def inject_conditions(interface, delay=None, jitter=None, loss=None,
                      bandwidth=None, corruption=None, duplication=None,
                      reorder=None):
    """Inject network conditions using tc/netem."""
    print(f"[*] Injecting conditions on {interface}")

    # First clear existing rules
    run_cmd(f"tc qdisc del dev {interface} root 2>/dev/null", check=False)

    # Build netem command
    netem_parts = ["tc", "qdisc", "add", "dev", interface, "root", "netem"]

    if delay:
        netem_parts.extend(["delay", delay])
        if jitter:
            netem_parts.append(jitter)

    if loss:
        netem_parts.extend(["loss", loss])

    if corruption:
        netem_parts.extend(["corrupt", corruption])

    if duplication:
        netem_parts.extend(["duplicate", duplication])

    if reorder:
        netem_parts.extend(["reorder", reorder])

    netem_cmd = " ".join(netem_parts)
    result = run_cmd(netem_cmd)

    if result.returncode != 0:
        print(f"[!] Failed to apply netem rules")
        return False

    # Apply bandwidth cap with tbf if specified
    if bandwidth:
        # tbf needs parent netem qdisc
        tbf_cmd = (
            f"tc qdisc add dev {interface} parent 1:1 handle 10: "
            f"tbf rate {bandwidth} burst 32kbit latency 400ms"
        )
        run_cmd(tbf_cmd)

    print(f"[+] Conditions applied successfully")
    print(f"    Delay: {delay or 'default'}")
    print(f"    Jitter: {jitter or 'none'}")
    print(f"    Loss: {loss or 'none'}")
    print(f"    Bandwidth: {bandwidth or 'default'}")
    print(f"    Corruption: {corruption or 'none'}")
    print(f"    Duplication: {duplication or 'none'}")
    print(f"    Reorder: {reorder or 'none'}")

    return True


def main():
    args = parse_args()

    if args.show:
        show_rules(args.interface)
        return

    if args.reset:
        reset_interface(args.interface)
        return

    # Check at least one condition is specified
    has_condition = any([args.delay, args.loss, args.bandwidth,
                         args.corruption, args.duplication, args.reorder])
    if not has_condition:
        print("[!] No conditions specified. Use --delay, --loss, --bandwidth, etc.")
        print("    Use --help for full options or --show to see current rules.")
        sys.exit(1)

    inject_conditions(
        interface=args.interface,
        delay=args.delay,
        jitter=args.jitter,
        loss=args.loss,
        bandwidth=args.bandwidth,
        corruption=args.corruption,
        duplication=args.duplication,
        reorder=args.reorder,
    )

    # Show final state
    print("\n[*] Final tc state:")
    show_rules(args.interface)


if __name__ == "__main__":
    main()
