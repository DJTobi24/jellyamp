#!/usr/bin/env python3
"""Prints the UDID of a simulator that exists on this machine.

    udid="$(python3 scripts/ci/pick-simulator.py)"                 # an iPhone
    udid="$(python3 scripts/ci/pick-simulator.py --family ipad)"   # an iPad
    udid="$(python3 scripts/ci/pick-simulator.py --screenshots)"   # 6.9" iPhone
    xcodebuild test -destination "platform=iOS Simulator,id=$udid" ...

Simulator names change with every Xcode release and differ between CI runner
images, so a hard-coded "iPhone 16" breaks sooner or later. This picks from
what `xcrun simctl` reports: the newest iOS runtime, preferring a plain
current iPhone over SE/mini/Max models (or, for iPad, a Pro over the rest).
If the image ships a runtime but no device for it, one is created.

`--screenshots` prefers the devices App Store Connect wants screenshots
from — the 6.9" "Pro Max" iPhone and the 13" iPad Pro — and falls back to
the nearest thing the machine has.

Diagnostics go to stderr; stdout carries only the UDID.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys


def simctl(*arguments: str) -> dict:
    result = subprocess.run(["xcrun", "simctl", *arguments, "--json"], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def runtime_version(identifier: str) -> tuple[int, ...] | None:
    """com.apple.CoreSimulator.SimRuntime.iOS-26-1 -> (26, 1); None if not iOS."""
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", identifier)
    return tuple(int(part) for part in match.group(1).split("-")) if match else None


def preference(name: str, family: str = "iphone", screenshots: bool = False) -> int:
    """How much a device of this name is wanted; 0 = not at all."""
    if family == "ipad":
        if not name.startswith("iPad"):
            return 0
        if screenshots:
            # 13" (12.9" on older runtimes) is the required iPad set.
            if re.match(r"iPad Pro 13-inch", name) or re.match(r"iPad Pro \(12\.9-inch\)", name):
                return 4
            if re.match(r"iPad Air 13-inch", name):
                return 3
        if name.startswith("iPad Pro 11"):
            return 2 if screenshots else 3
        if name.startswith("iPad Pro") or name.startswith("iPad Air"):
            return 2
        return 1

    if screenshots:
        # 6.9" is the required iPhone set; "Plus" models have the same class of display.
        if re.fullmatch(r"iPhone \d+ Pro Max", name):
            return 5
        if re.fullmatch(r"iPhone \d+ Plus", name) or re.fullmatch(r"iPhone Air", name):
            return 4
    if re.fullmatch(r"iPhone \d+", name):
        return 3
    if re.fullmatch(r"iPhone \d+ Pro", name):
        return 2
    if name.startswith("iPhone"):
        return 1
    return 0


def existing_device(family: str, screenshots: bool) -> dict | None:
    candidates = []
    for runtime, devices in simctl("list", "devices", "available").get("devices", {}).items():
        version = runtime_version(runtime)
        if version is None:
            continue
        for device in devices:
            wanted = preference(device["name"], family, screenshots)
            if device.get("isAvailable", True) and wanted > 0:
                candidates.append((version, wanted, device["name"], device))
    if not candidates:
        return None
    version, _, name, device = max(candidates, key=lambda candidate: candidate[:3])
    print(f"Using {name} (iOS {'.'.join(map(str, version))}), {device['udid']}", file=sys.stderr)
    return device


def created_device(family: str, screenshots: bool) -> str | None:
    runtimes = [
        (runtime_version(runtime["identifier"]), runtime)
        for runtime in simctl("list", "runtimes").get("runtimes", [])
        if runtime.get("isAvailable") and runtime_version(runtime["identifier"])
    ]
    if not runtimes:
        return None
    version, runtime = max(runtimes, key=lambda item: item[0])

    def wanted(device_type: dict) -> int:
        return preference(device_type["name"], family, screenshots)

    supported = [device_type for device_type in runtime.get("supportedDeviceTypes", []) if wanted(device_type) > 0]
    if not supported:
        supported = [
            device_type for device_type in simctl("list", "devicetypes").get("devicetypes", []) if wanted(device_type) > 0
        ]
    if not supported:
        return None
    # Later entries are newer models; among those take the most wanted one.
    device_type = max(enumerate(supported), key=lambda item: (wanted(item[1]), item[0]))[1]

    label = "iPad" if family == "ipad" else "iPhone"
    result = subprocess.run(
        ["xcrun", "simctl", "create", f"Jellyamp CI {label}", device_type["identifier"], runtime["identifier"]],
        check=True,
        capture_output=True,
        text=True,
    )
    udid = result.stdout.strip()
    print(f"Created {device_type['name']} (iOS {'.'.join(map(str, version))}), {udid}", file=sys.stderr)
    return udid


def main() -> int:
    parser = argparse.ArgumentParser(description="Print the UDID of an available iOS simulator.")
    parser.add_argument("--family", choices=["iphone", "ipad"], default="iphone")
    parser.add_argument("--screenshots", action="store_true", help="prefer the App Store screenshot sizes (6.9\" / 13\")")
    arguments = parser.parse_args()

    device = existing_device(arguments.family, arguments.screenshots)
    udid = device["udid"] if device else created_device(arguments.family, arguments.screenshots)
    if not udid:
        print(
            f"error: no iOS simulator runtime with an {arguments.family} device is installed (xcrun simctl list runtimes)",
            file=sys.stderr,
        )
        return 1
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
