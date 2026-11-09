#!/usr/bin/env python3
"""Prints the UDID of an iPhone simulator that exists on this machine.

    udid="$(python3 scripts/ci/pick-simulator.py)"
    xcodebuild test -destination "platform=iOS Simulator,id=$udid" ...

Simulator names change with every Xcode release and differ between CI runner
images, so a hard-coded "iPhone 16" breaks sooner or later. This picks from
what `xcrun simctl` reports: the newest iOS runtime, preferring a plain
current iPhone over SE/mini/Max models. If the image ships a runtime but no
device for it, one is created. Diagnostics go to stderr; stdout carries only
the UDID.
"""

from __future__ import annotations

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


def preference(name: str) -> int:
    if re.fullmatch(r"iPhone \d+", name):
        return 3
    if re.fullmatch(r"iPhone \d+ Pro", name):
        return 2
    if name.startswith("iPhone"):
        return 1
    return 0


def existing_device() -> dict | None:
    candidates = []
    for runtime, devices in simctl("list", "devices", "available").get("devices", {}).items():
        version = runtime_version(runtime)
        if version is None:
            continue
        for device in devices:
            if device.get("isAvailable", True) and preference(device["name"]) > 0:
                candidates.append((version, preference(device["name"]), device["name"], device))
    if not candidates:
        return None
    version, _, name, device = max(candidates, key=lambda candidate: candidate[:3])
    print(f"Using {name} (iOS {'.'.join(map(str, version))}), {device['udid']}", file=sys.stderr)
    return device


def created_device() -> str | None:
    runtimes = [
        (runtime_version(runtime["identifier"]), runtime)
        for runtime in simctl("list", "runtimes").get("runtimes", [])
        if runtime.get("isAvailable") and runtime_version(runtime["identifier"])
    ]
    if not runtimes:
        return None
    version, runtime = max(runtimes, key=lambda item: item[0])

    supported = [device_type for device_type in runtime.get("supportedDeviceTypes", []) if preference(device_type["name"]) > 0]
    if not supported:
        supported = [
            device_type
            for device_type in simctl("list", "devicetypes").get("devicetypes", [])
            if preference(device_type["name"]) > 0
        ]
    if not supported:
        return None
    # Later entries are newer models; among those take the most plain one.
    device_type = max(enumerate(supported), key=lambda item: (preference(item[1]["name"]), item[0]))[1]

    result = subprocess.run(
        ["xcrun", "simctl", "create", "Jellyamp CI iPhone", device_type["identifier"], runtime["identifier"]],
        check=True,
        capture_output=True,
        text=True,
    )
    udid = result.stdout.strip()
    print(f"Created {device_type['name']} (iOS {'.'.join(map(str, version))}), {udid}", file=sys.stderr)
    return udid


def main() -> int:
    device = existing_device()
    udid = device["udid"] if device else created_device()
    if not udid:
        print("error: no iOS simulator runtime is installed (xcrun simctl list runtimes)", file=sys.stderr)
        return 1
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
