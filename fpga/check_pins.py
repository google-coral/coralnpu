#!/usr/bin/env python3
# Copyright 2026 Google LLC

import argparse
import sys
import re


def parse_verilog_ports(sv_file):
    ports = {}
    # Regex to match input/output/inout
    # Group 1: direction
    # Group 2: array range (optional)
    # Group 3: name
    regex = re.compile(
        r'^\s*(input|output|inout)\s+(?:logic|reg|wire)?\s*(?:\[([^\]]+)\])?\s*([a-zA-Z0-9_]+)\s*,?\s*'
    )

    with open(sv_file, 'r') as f:
        for line in f:
            # Strip comments
            line = line.split('//')[0]
            match = regex.match(line)
            if match:
                direction = match.group(1)
                width_range = match.group(2)
                name = match.group(3)

                # Parse width
                width = 1
                if width_range:
                    parts = width_range.split(':')
                    if len(parts) == 2:
                        try:
                            h = int(parts[0].strip())
                            l = int(parts[1].strip())
                            width = abs(h - l) + 1
                        except ValueError:
                            # Parametric range (e.g. PARAM-1:0)
                            # We reset to 1 to trigger the fallback logic in main()
                            width = 1

                ports[name] = {
                    'direction': direction,
                    'width': width,
                    'range': width_range
                }
    return ports


# Known non-I/O (VCCO_75, GND, VRP/VREF, NC) balls in/near UltraScale Bank 75 on XCVU13P-FHGA2104
FORBIDDEN_NEXUS_BALLS = {
    "A17": "VCCO_75",
    "D18": "VCCO_75",
    "G19": "VCCO_75",
    "H16": "VCCO_75",
    "L17": "VCCO_75",
    "P18": "VCCO_75",
    "T18": "B75_VRP",
    "T19": "B75_VREF",
    "H17": "NC (Bank 75)",
    "B19": "GND",
    "J18": "GND",
    "G14": "GND",
}


def parse_xdc_mappings(xdc_file):
    mappings = set()
    pin_to_ports = {}
    port_to_pins = {}
    # Match port lists inside [get_ports ...], including optional -quiet and braces or quotes.
    port_regex = re.compile(
        r'\[\s*get_ports(?:\s+-quiet)?\s+[\{\"]?\s*([a-zA-Z0-9_\[\],\s\*]+)\s*[\}\"]?\s*\]'
    )
    pkg_pin_regex = re.compile(r'\bPACKAGE_PIN\s+([A-Z]+\d+)\b')

    with open(xdc_file, 'r') as f:
        for line in f:
            if '#' in line:
                line = line.split('#')[0]
            pkg_match = pkg_pin_regex.search(line)
            if not pkg_match:
                continue
            ball = pkg_match.group(1)
            matches = port_regex.findall(line)
            for m in matches:
                # Split by whitespace or comma when multiple ports are listed.
                for p in re.split(r'[\s,]+', m):
                    port = p.strip()
                    if port and '*' not in port:
                        mappings.add(port)
                        pin_to_ports.setdefault(ball, []).append(port)
                        port_to_pins.setdefault(port, []).append(ball)
    return mappings, pin_to_ports, port_to_pins


def check_pins(sv_file, xdc_files):
    """Validate top-level SystemVerilog ports against XDC PACKAGE_PIN assignments.

    Returns a tuple (missing, duplicates, multi_assigned_ports, forbidden).
    """
    ports = parse_verilog_ports(sv_file)

    mappings = set()
    pin_to_ports = {}
    port_to_pins = {}
    for xdc in xdc_files:
        xdc_mappings, xdc_pins, xdc_port_pins = parse_xdc_mappings(xdc)
        mappings.update(xdc_mappings)
        for ball, plist in xdc_pins.items():
            pin_to_ports.setdefault(ball, []).extend(plist)
        for port, blist in xdc_port_pins.items():
            port_to_pins.setdefault(port, []).extend(blist)

    # Auto-detect if DDR mappings were provided in any XDC
    has_ddr_mappings = any(m.startswith("c0_ddr4_") for m in mappings)
    should_ignore_ddr = not has_ddr_mappings

    if should_ignore_ddr:
        print(
            "===================================================================================================="
        )
        print(
            "PIN CHECKER: DDR pin check is DISABLED (no DDR4 mappings found in XDC or forced ignore)"
        )
        print(
            "===================================================================================================="
        )
    else:
        print(
            "===================================================================================================="
        )
        print(
            "PIN CHECKER: DDR pin check is ENABLED (DDR4 mappings found in XDC)"
        )
        print(
            "===================================================================================================="
        )

    missing = []

    for name, info in ports.items():
        if should_ignore_ddr and (name.startswith("c0_ddr4_") or name
                                  == "c0_sys_clk_n" or name == "c0_sys_clk_p"):
            continue

        if info['width'] > 1:
            if info['range']:
                parts = info['range'].split(':')
                if len(parts) == 2:
                    try:
                        h = int(parts[0].strip())
                        l = int(parts[1].strip())
                        step = 1 if h >= l else -1
                        for i in range(l, h + step, step):
                            bit_name = f"{name}[{i}]"
                            if bit_name not in mappings:
                                missing.append(bit_name)
                    except ValueError:
                        print(
                            f"Warning: Parametric range for vector {name}: {info['range']}. Doing fallback prefix check."
                        )
                        found_base = False
                        for m in mappings:
                            if m.startswith(name):
                                found_base = True
                                break
                        if not found_base:
                            missing.append(name)
        else:
            # Fallback for vectors without a parsed range
            if name not in mappings:
                found_base = False
                for m in mappings:
                    if m.startswith(name):
                        found_base = True
                        break
                if not found_base:
                    missing.append(name)

    duplicates = {
        ball: sorted(set(plist))
        for ball, plist in pin_to_ports.items()
        if len(set(plist)) > 1
    }
    multi_assigned_ports = {
        port: blist
        for port, blist in port_to_pins.items()
        if len(blist) > 1
    }
    forbidden = {
        ball: (FORBIDDEN_NEXUS_BALLS[ball], sorted(set(plist)))
        for ball, plist in pin_to_ports.items()
        if ball in FORBIDDEN_NEXUS_BALLS
    }
    return missing, duplicates, multi_assigned_ports, forbidden


def main():
    parser = argparse.ArgumentParser(
        description="Verify top-level SystemVerilog ports are mapped in XDC."
    )
    parser.add_argument(
        "--xdc",
        action="append",
        required=True,
        help="Path to XDC file(s). Can use multiple times."
    )
    parser.add_argument(
        "--sv", required=True, help="Path to top-level SystemVerilog file."
    )

    args = parser.parse_args()

    missing, duplicates, multi_assigned_ports, forbidden = check_pins(
        args.sv, args.xdc
    )

    has_error = False
    if missing:
        print("ERROR: Missing pin mappings for some top-level ports:")
        for m in missing:
            print(f"  - {m}")
        has_error = True

    if duplicates:
        print("ERROR: Duplicate PACKAGE_PIN assignments detected:")
        for ball, plist in sorted(duplicates.items()):
            print(f"  - {ball}: {', '.join(plist)}")
        has_error = True

    if multi_assigned_ports:
        print("ERROR: Ports assigned multiple PACKAGE_PIN locations:")
        for port, blist in sorted(multi_assigned_ports.items()):
            print(f"  - {port}: {', '.join(blist)}")
        has_error = True

    if forbidden:
        print("ERROR: Ports assigned to non-I/O (power/ground/NC) balls:")
        for ball, (reason, plist) in sorted(forbidden.items()):
            print(f"  - {ball} ({reason}): {', '.join(plist)}")
        has_error = True

    if has_error:
        sys.exit(1)

    print("All top-level ports are mapped to unique, valid pins!")
    sys.exit(0)


if __name__ == "__main__":
    main()
