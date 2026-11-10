#!/usr/bin/env python3
"""Prints the crash reports written since a point in time, condensed.

    scripts/ci/print-crash-reports.py --since <unix time> [--limit 3]

When the app (or the app hosting the unit tests) dies during a test run,
xcodebuild only says "Restarting after unexpected exit, crash, or test
timeout". The reason is in the crash report the system writes to
~/Library/Logs/DiagnosticReports — for simulator processes too. This script
prints, per report: the exception, the message the process left behind
(`fatalError` text, the reason of an uncaught NSException), and the
backtraces that matter, so a crash on CI can be diagnosed from the job log.

Reports are `.ips` files: one line of JSON metadata followed by a JSON body.
Anything that does not parse is printed raw (first lines only). The script
never fails the build: it always exits with status 0.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPORT_DIRECTORIES = [
    pathlib.Path.home() / "Library/Logs/DiagnosticReports",
    pathlib.Path("/Library/Logs/DiagnosticReports"),
]
MAX_FRAMES = 28


def frames(thread_frames: list, images: list) -> list[str]:
    lines = []
    for index, frame in enumerate(thread_frames[:MAX_FRAMES]):
        image = ""
        image_index = frame.get("imageIndex")
        if isinstance(image_index, int) and 0 <= image_index < len(images):
            image = images[image_index].get("name", "")
        symbol = frame.get("symbol") or hex(frame.get("imageOffset", 0))
        location = ""
        if frame.get("sourceFile"):
            location = f"  ({frame['sourceFile']}:{frame.get('sourceLine', '?')})"
        lines.append(f"    {index:2d}  {image:<28} {symbol}{location}")
    if len(thread_frames) > MAX_FRAMES:
        lines.append(f"    … {len(thread_frames) - MAX_FRAMES} more frames")
    return lines


def describe(path: pathlib.Path) -> list[str]:
    text = path.read_text(errors="replace")
    head, _, rest = text.partition("\n")
    try:
        body = json.loads(rest)
    except ValueError:
        return text.splitlines()[:80]

    out = []
    exception = body.get("exception", {})
    out.append(f"process:     {body.get('procName', '?')} (parent: {body.get('parentProc', '?')})")
    out.append(f"exception:   {exception.get('type', '?')} {exception.get('signal', '')} {exception.get('subtype', '')}".rstrip())
    termination = body.get("termination", {})
    if termination:
        out.append(f"termination: {termination.get('namespace', '')} {termination.get('indicator', '')}".rstrip())
        for reason in termination.get("reasons", []) or []:
            out.append(f"             {reason}")
    # "Application Specific Information": fatalError / precondition text,
    # the reason of an uncaught Objective-C exception.
    for library, messages in (body.get("asi") or {}).items():
        for message in messages:
            out.append(f"message ({library}): {message}")
    images = body.get("usedImages", [])
    last_exception = body.get("lastExceptionBacktrace")
    if last_exception:
        out.append("last exception backtrace:")
        out.extend(frames(last_exception, images))
    for thread in body.get("threads", []):
        if thread.get("triggered"):
            name = thread.get("name") or thread.get("queue") or ""
            out.append(f"crashed thread {name}:".replace(" :", ":"))
            out.extend(frames(thread.get("frames", []), images))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--since", type=float, default=0, help="only reports modified after this unix time")
    parser.add_argument("--limit", type=int, default=3, help="print at most this many reports (oldest first)")
    arguments = parser.parse_args()

    reports = []
    for directory in REPORT_DIRECTORIES:
        if not directory.is_dir():
            continue
        for path in directory.rglob("*"):
            try:
                if path.is_file() and path.suffix in (".ips", ".crash") and path.stat().st_mtime >= arguments.since:
                    reports.append((path.stat().st_mtime, path))
            except OSError:
                continue
    reports.sort()
    if not reports:
        print("(no crash reports were written during this step)")
        return 0
    print(f"{len(reports)} crash report(s) written during this step:")
    for _, path in reports:
        print(f"  {path.name}")
    for _, path in reports[: arguments.limit]:
        print("")
        print(f"=== {path.name}")
        try:
            for line in describe(path):
                print(line)
        except Exception as error:  # noqa: BLE001 - diagnostics must never fail the build
            print(f"(could not read the report: {error})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001
        print(f"print-crash-reports: {error}")
        sys.exit(0)
