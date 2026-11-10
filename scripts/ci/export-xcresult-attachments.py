#!/usr/bin/env python3
"""Pulls screenshots (and other test attachments) out of an .xcresult bundle.

    scripts/ci/export-xcresult-attachments.py build/UITests.xcresult out/en-US --suffix iphone

The screenshot UI tests (ios/JellyampUITests/ScreenshotTests.swift) attach
every screenshot under a name such as "03-now-playing". Those end up as

    <output>/03-now-playing-<suffix>.png

Every other attachment — above all the screenshots Xcode takes when a test
fails — goes to <output>/other/, so a failed CI run can be looked at without
opening the result bundle in Xcode.

`xcresulttool` changed its command line with Xcode 16: `export attachments`
writes all attachments plus a manifest in one go. Older Xcodes only have the
object-graph commands (`get` / `export --type file`), which Xcode 16 still
offers behind `--legacy`. Both are tried, in that order. If neither works the
script says so and exits with status 0 unless --strict is given: a missing
screenshot must not turn a green test run red.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

# "03-now-playing": what ScreenshotTests names its attachments.
SCREENSHOT_NAME = re.compile(r"^\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$")
# Xcode appends "_<index>_<UUID>" to an attachment's name when exporting.
EXPORT_SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")
UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")


def log(message: str) -> None:
    print(message, file=sys.stderr)


def run(arguments: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, capture_output=True, text=True)


def attachment_base_name(name: str) -> str:
    """'03-now-playing_0_6F9A….png' or '03-now-playing.png' -> '03-now-playing'."""
    stem = pathlib.PurePosixPath(name).stem if "." in name else name
    return EXPORT_SUFFIX.sub("", stem)


class Collector:
    def __init__(self, output: pathlib.Path, suffix: str, screenshots_only: bool) -> None:
        self.output = output
        self.suffix = suffix
        self.screenshots_only = screenshots_only
        self.screenshots = 0
        self.others = 0

    def add(self, source: pathlib.Path, name: str, test: str) -> None:
        if not source.is_file():
            return
        base = attachment_base_name(name)
        extension = source.suffix or pathlib.PurePosixPath(name).suffix or ".png"
        if SCREENSHOT_NAME.match(base):
            self.output.mkdir(parents=True, exist_ok=True)
            target = self.output / f"{base}{'-' + self.suffix if self.suffix else ''}{extension}"
            shutil.copyfile(source, target)
            self.screenshots += 1
            return
        if self.screenshots_only:
            return
        folder = self.output / "other" / (UNSAFE.sub("_", test).strip("_") or "unknown-test")
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / (UNSAFE.sub("_", name) or source.name)
        if not target.suffix:
            target = target.with_suffix(extension)
        counter = 1
        while target.exists():
            target = folder / f"{target.stem}-{counter}{target.suffix}"
            counter += 1
        shutil.copyfile(source, target)
        self.others += 1


# --- Xcode 16+: `xcresulttool export attachments` ---------------------------


def export_modern(bundle: pathlib.Path, collector: Collector) -> bool:
    with tempfile.TemporaryDirectory() as scratch:
        result = run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", scratch])
        if result.returncode != 0:
            reason = (result.stderr.strip().splitlines() or ["no message"])[-1]
            log(f"xcresulttool export attachments is not available here ({reason})")
            return False
        manifest_path = pathlib.Path(scratch) / "manifest.json"
        if not manifest_path.is_file():
            log("xcresulttool export attachments wrote no manifest.json")
            return False
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except ValueError as error:
            log(f"manifest.json is not valid JSON: {error}")
            return False
        entries = manifest if isinstance(manifest, list) else manifest.get("tests", [])
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            test = str(entry.get("testIdentifier") or "")
            for attachment in entry.get("attachments") or []:
                exported = attachment.get("exportedFileName")
                if not exported:
                    continue
                name = attachment.get("suggestedHumanReadableName") or exported
                collector.add(pathlib.Path(scratch) / exported, str(name), test)
        return True


# --- Xcode 15 and earlier (or `--legacy`): walk the object graph -------------


class LegacyReader:
    def __init__(self, bundle: pathlib.Path) -> None:
        self.bundle = bundle
        # Xcode 16 hides these commands behind --legacy; older ones reject the flag.
        self.flags: list[str] | None = None

    def _attempt(self, arguments: list[str]) -> subprocess.CompletedProcess | None:
        candidates = [self.flags] if self.flags is not None else [[], ["--legacy"]]
        for flags in candidates:
            result = run(["xcrun", "xcresulttool", *arguments, *flags])
            if result.returncode == 0:
                self.flags = flags
                return result
        return None

    def get(self, identifier: str | None = None) -> dict | None:
        arguments = ["get", "--format", "json", "--path", str(self.bundle)]
        if identifier:
            arguments += ["--id", identifier]
        result = self._attempt(arguments)
        if result is None:
            return None
        try:
            return json.loads(result.stdout)
        except ValueError:
            return None

    def export_file(self, identifier: str, target: pathlib.Path) -> bool:
        arguments = ["export", "--type", "file", "--path", str(self.bundle), "--id", identifier, "--output-path", str(target)]
        return self._attempt(arguments) is not None


def values(node: dict | None, key: str) -> list[dict]:
    return ((node or {}).get(key) or {}).get("_values") or []


def value(node: dict | None, *keys: str) -> str | None:
    for key in keys:
        node = (node or {}).get(key)
    return (node or {}).get("_value") if isinstance(node, dict) else None


def export_legacy(bundle: pathlib.Path, collector: Collector) -> bool:
    reader = LegacyReader(bundle)
    root = reader.get()
    if root is None:
        log("xcresulttool get is not available here either")
        return False

    def walk_activities(activities: list[dict], test: str, scratch: pathlib.Path) -> None:
        for activity in activities:
            for attachment in values(activity, "attachments"):
                payload = value(attachment, "payloadRef", "id")
                if not payload:
                    continue
                name = value(attachment, "name") or value(attachment, "filename") or payload
                filename = value(attachment, "filename") or f"{payload}.png"
                target = scratch / (UNSAFE.sub("_", payload) + pathlib.PurePosixPath(filename).suffix)
                if reader.export_file(payload, target):
                    collector.add(target, name, test)
            walk_activities(values(activity, "subactivities"), test, scratch)

    def walk_tests(tests: list[dict], scratch: pathlib.Path) -> None:
        for test in tests:
            walk_tests(values(test, "subtests"), scratch)
            summary_id = value(test, "summaryRef", "id")
            if not summary_id:
                continue
            summary = reader.get(summary_id)
            identifier = value(test, "identifier") or value(test, "name") or ""
            walk_activities(values(summary, "activitySummaries"), identifier, scratch)

    with tempfile.TemporaryDirectory() as scratch_name:
        scratch = pathlib.Path(scratch_name)
        for action in values(root, "actions"):
            tests_id = value(action.get("actionResult"), "testsRef", "id")
            if not tests_id:
                continue
            plan = reader.get(tests_id)
            for summary in values(plan, "summaries"):
                for testable in values(summary, "testableSummaries"):
                    walk_tests(values(testable, "tests"), scratch)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Export screenshots and attachments from an .xcresult bundle.")
    parser.add_argument("xcresult", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--suffix", default="", help="appended to screenshot names, e.g. the device: 01-home-<suffix>.png")
    parser.add_argument("--screenshots-only", action="store_true", help="skip attachments that are not named screenshots")
    parser.add_argument("--strict", action="store_true", help="fail when nothing could be exported or no screenshot was found")
    arguments = parser.parse_args()

    if not arguments.xcresult.exists():
        log(f"{arguments.xcresult} does not exist (the tests did not get as far as writing a result bundle)")
        return 1 if arguments.strict else 0

    collector = Collector(arguments.output, arguments.suffix, arguments.screenshots_only)
    exported = False
    for exporter in (export_modern, export_legacy):
        try:
            exported = exporter(arguments.xcresult, collector)
        except OSError as error:   # no xcrun at all, unwritable output, …
            log(f"{exporter.__name__} failed: {error}")
            exported = False
        if exported:
            break

    if not exported:
        log("Could not read attachments from the result bundle with this Xcode. Open it in Xcode instead.")
        return 1 if arguments.strict else 0
    log(f"Exported {collector.screenshots} screenshot(s) and {collector.others} other attachment(s) to {arguments.output}")
    if arguments.strict and collector.screenshots == 0:
        log("error: the result bundle contains no screenshot attachment")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
