#!/usr/bin/env python3
"""Checks everything App Store Connect would reject, before Apple does.

Runs on any machine with Python 3.9+ (standard library only); CI runs it on
every push (.github/workflows/ios.yml) and `fastlane release` runs it before
uploading.

    python3 scripts/check-appstore-metadata.py

Checked:
  * listing texts in ios/fastlane/metadata: required files, App Store length
    limits, keyword formatting, other companies' trademarks, https URLs
  * the same URLs and bundle identifier everywhere they are repeated
  * app icon: 1024x1024, opaque where the App Store demands it
  * privacy manifest and asset catalog are well-formed
  * release-critical Info.plist settings in ios/project.yml
  * the in-app license text matches LICENSE
"""

from __future__ import annotations

import json
import plistlib
import re
import struct
import sys
import textwrap
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IOS = REPO / "ios"
METADATA = IOS / "fastlane" / "metadata"
RESOURCES = IOS / "Jellyamp" / "Resources"
ASSETS = RESOURCES / "Assets.xcassets"

LOCALES = ("en-US", "de-DE")

# App Store Connect limits, in characters.
LOCALIZED_LIMITS = {
    "name.txt": 30,
    "subtitle.txt": 30,
    "keywords.txt": 100,
    "promotional_text.txt": 170,
    "description.txt": 4000,
    "release_notes.txt": 4000,
}
URL_FILES = ("marketing_url.txt", "support_url.txt", "privacy_url.txt")
REVIEW_NOTES_LIMIT = 4000

# Guideline 2.3.7 / 5.2.1: no other companies' product names in the listing,
# no references to other platforms, no "beta"/"test" wording.
FORBIDDEN_TERMS = (
    "plex",
    "plexamp",
    "spotify",
    "apple music",
    "itunes",
    "tidal",
    "deezer",
    "youtube",
    "soundcloud",
    "roon",
    "navidrome",
    "subsonic",
    "android",
    "google play",
    "beta",
    "testflight",
)

# Required-reason API categories and the reason codes Apple defines for them.
PRIVACY_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
}

errors: list[str] = []


def fail(message: str) -> None:
    errors.append(message)


def rel(path: Path) -> str:
    return str(path.relative_to(REPO))


def read(path: Path) -> str | None:
    if not path.is_file():
        fail(f"{rel(path)}: missing")
        return None
    return path.read_text(encoding="utf-8").strip()


# --------------------------------------------------------------------------
# Listing texts
# --------------------------------------------------------------------------


def check_listing() -> dict[str, str]:
    """Validates the per-locale texts; returns the URLs of the first locale."""
    urls: dict[str, str] = {}
    for locale in LOCALES:
        folder = METADATA / locale
        for name, limit in LOCALIZED_LIMITS.items():
            text = read(folder / name)
            if text is None:
                continue
            if not text:
                fail(f"{rel(folder / name)}: empty")
            if len(text) > limit:
                fail(f"{rel(folder / name)}: {len(text)} characters, limit is {limit}")
            lowered = text.lower()
            for term in FORBIDDEN_TERMS:
                if re.search(rf"(?<![a-z]){re.escape(term)}(?![a-z])", lowered):
                    fail(f"{rel(folder / name)}: contains \"{term}\" (trademark / platform / beta wording)")

        keywords = read(folder / "keywords.txt")
        if keywords:
            if "\n" in keywords:
                fail(f"{rel(folder / 'keywords.txt')}: must be a single line")
            parts = keywords.split(",")
            if any(part != part.strip() or not part for part in parts):
                fail(f"{rel(folder / 'keywords.txt')}: separate keywords with commas only, no spaces or empty entries")
            lowered_parts = [part.strip().lower() for part in parts]
            duplicates = sorted({part for part in lowered_parts if lowered_parts.count(part) > 1})
            if duplicates:
                fail(f"{rel(folder / 'keywords.txt')}: duplicate keywords {duplicates}")
            # Words already in the name or subtitle are indexed anyway.
            title_words = set(
                re.findall(r"\w+", ((read(folder / "name.txt") or "") + " " + (read(folder / "subtitle.txt") or "")).lower())
            )
            wasted = sorted(set(lowered_parts) & title_words)
            if wasted:
                fail(f"{rel(folder / 'keywords.txt')}: {wasted} repeat the name/subtitle and waste keyword space")

        for name in URL_FILES:
            url = read(folder / name)
            if url is None:
                continue
            if not re.fullmatch(r"https://[^\s]+", url):
                fail(f"{rel(folder / name)}: must be a single https:// URL")
            if urls.setdefault(name, url) != url:
                fail(f"{rel(folder / name)}: differs from {LOCALES[0]}/{name}")

    copyright_text = read(METADATA / "copyright.txt")
    if copyright_text is not None and not re.fullmatch(r"\d{4} \S.*", copyright_text):
        fail("copyright.txt: expected \"<year> <owner>\" without a © symbol (App Store Connect adds it)")

    category = read(METADATA / "primary_category.txt")
    if category is not None and category != "MUSIC":
        fail("primary_category.txt: expected MUSIC")

    notes = read(METADATA / "review_information" / "notes.txt")
    if notes is not None:
        if len(notes) > REVIEW_NOTES_LIMIT:
            fail(f"review_information/notes.txt: {len(notes)} characters, limit is {REVIEW_NOTES_LIMIT}")
        if "demo.jellyfin.org" not in notes:
            fail("review_information/notes.txt: must tell the reviewer how to sign in (demo server)")

    rating_path = METADATA / "app_rating.json"
    try:
        json.loads(rating_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        fail(f"{rel(rating_path)}: {error}")
    return urls


# --------------------------------------------------------------------------
# Values repeated in several files
# --------------------------------------------------------------------------


def check_consistency(urls: dict[str, str]) -> None:
    about = read(IOS / "Jellyamp" / "Features" / "Settings" / "AboutView.swift") or ""
    for name in ("support_url.txt", "privacy_url.txt"):
        url = urls.get(name)
        if url and f'"{url}"' not in about:
            fail(f"AboutView.swift: does not link to {url} ({name})")

    pages = read(REPO / "docs" / "_config.yml") or ""
    for url in urls.values():
        if url not in pages:
            fail(f"docs/_config.yml: does not mention {url}; is the page still published there?")
    for page, permalink in (("PRIVACY.md", "/privacy/"), ("SUPPORT.md", "/support/")):
        text = read(REPO / "docs" / page) or ""
        if f"permalink: {permalink}" not in text:
            fail(f"docs/{page}: front matter must keep \"permalink: {permalink}\"")

    project = read(IOS / "project.yml") or ""
    match = re.search(r"^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)\s*$", project, re.MULTILINE)
    bundle_id = match.group(1) if match else None
    if not bundle_id:
        fail("ios/project.yml: PRODUCT_BUNDLE_IDENTIFIER not found")
    else:
        for name in ("Appfile", "Fastfile"):
            if f'"{bundle_id}"' not in (read(IOS / "fastlane" / name) or ""):
                fail(f"ios/fastlane/{name}: app identifier differs from project.yml ({bundle_id})")

    license_text = read(REPO / "LICENSE") or ""
    embedded = re.search(r'static let jellyamp = """\n(.*?)\n\s*"""', about, re.DOTALL)
    if not embedded:
        fail("AboutView.swift: LicenseText.jellyamp not found")
    elif textwrap.dedent(embedded.group(1)).strip() != license_text:
        fail("AboutView.swift: LicenseText.jellyamp differs from LICENSE")


# --------------------------------------------------------------------------
# project.yml: settings a release depends on
# --------------------------------------------------------------------------


def check_project() -> None:
    project = read(IOS / "project.yml")
    if project is None:
        return
    # Comments explain why some keys are absent; only look at real settings.
    settings = "\n".join(line for line in project.splitlines() if not line.lstrip().startswith("#"))

    if not re.search(r'^\s*MARKETING_VERSION:\s*"\d+\.\d+(\.\d+)?"\s*$', settings, re.MULTILINE):
        fail("ios/project.yml: MARKETING_VERSION must be a quoted version such as \"1.2.0\"")
    for needle, why in (
        ("CFBundleShortVersionString: $(MARKETING_VERSION)", "version must come from the build setting"),
        ("CFBundleVersion: $(CURRENT_PROJECT_VERSION)", "build number must come from the build setting"),
        ("ITSAppUsesNonExemptEncryption: false", "export compliance declaration"),
        ("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon", "app icon"),
    ):
        if needle not in settings:
            fail(f"ios/project.yml: missing \"{needle}\" ({why})")
    # Their presence silently disables NSAllowsArbitraryLoads on iOS 10+.
    for key in ("NSAllowsLocalNetworking", "NSAllowsArbitraryLoadsForMedia", "NSAllowsArbitraryLoadsInWebContent"):
        if re.search(rf"^\s*{key}:", settings, re.MULTILINE) and "NSAllowsArbitraryLoads: true" in settings:
            fail(f"ios/project.yml: {key} makes iOS ignore NSAllowsArbitraryLoads; keep only one of them")
    if re.search(r"^\s*DEVELOPMENT_TEAM:\s*\S", settings, re.MULTILINE):
        fail("ios/project.yml: DEVELOPMENT_TEAM belongs in the untracked Config/Signing.xcconfig")
    if "UIRequiresFullScreen" in settings:
        fail("ios/project.yml: UIRequiresFullScreen opts out of iPad multitasking; remove it")


# --------------------------------------------------------------------------
# Bundle resources
# --------------------------------------------------------------------------


def png_header(path: Path) -> tuple[int, int, int] | None:
    """(width, height, colour type) from a PNG's IHDR chunk."""
    try:
        data = path.read_bytes()[:26]
    except OSError:
        fail(f"{rel(path)}: missing")
        return None
    if len(data) < 26 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        fail(f"{rel(path)}: not a PNG file")
        return None
    width, height = struct.unpack(">II", data[16:24])
    return width, height, data[25]


def check_assets() -> None:
    for contents in sorted(ASSETS.rglob("Contents.json")):
        try:
            catalog = json.loads(contents.read_text(encoding="utf-8"))
        except ValueError as error:
            fail(f"{rel(contents)}: {error}")
            continue
        for image in catalog.get("images", []):
            filename = image.get("filename")
            if filename and not (contents.parent / filename).is_file():
                fail(f"{rel(contents)}: references missing file {filename}")

    for name in ("AppIcon.appiconset", "AccentColor.colorset", "LaunchBackground.colorset", "AppLogo.imageset"):
        if not (ASSETS / name / "Contents.json").is_file():
            fail(f"{rel(ASSETS / name)}: missing (run scripts/generate-app-icon.py)")

    # PNG colour types with an alpha channel: 4 (grey+alpha) and 6 (RGBA).
    icon_set = ASSETS / "AppIcon.appiconset"
    for filename, alpha_allowed in (("AppIcon.png", False), ("AppIcon-Tinted.png", False), ("AppIcon-Dark.png", True)):
        header = png_header(icon_set / filename)
        if header is None:
            continue
        width, height, colour_type = header
        if (width, height) != (1024, 1024):
            fail(f"{filename}: is {width}x{height}, must be 1024x1024")
        if colour_type in (4, 6) and not alpha_allowed:
            fail(f"{filename}: has an alpha channel; App Store Connect rejects transparent app icons")


def check_privacy_manifest() -> None:
    path = RESOURCES / "PrivacyInfo.xcprivacy"
    try:
        with path.open("rb") as handle:
            manifest = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        fail(f"{rel(path)}: {error}")
        return

    if manifest.get("NSPrivacyTracking") is not False:
        fail("PrivacyInfo.xcprivacy: NSPrivacyTracking must be false")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        fail("PrivacyInfo.xcprivacy: NSPrivacyTrackingDomains must be empty")
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        fail("PrivacyInfo.xcprivacy: NSPrivacyCollectedDataTypes must be empty (label is \"Data Not Collected\")")

    declared = set()
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        category = entry.get("NSPrivacyAccessedAPIType")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons") or []
        declared.add(category)
        if category not in PRIVACY_REASONS:
            fail(f"PrivacyInfo.xcprivacy: unknown API category {category}")
        elif not reasons or not set(reasons) <= PRIVACY_REASONS[category]:
            fail(f"PrivacyInfo.xcprivacy: invalid reasons {reasons} for {category}")

    # The app must declare every required-reason API its own sources use.
    sources = "\n".join(
        path.read_text(encoding="utf-8")
        for folder in (IOS / "Jellyamp", IOS / "Packages")
        for path in folder.rglob("*.swift")
        if "/Tests/" not in path.as_posix() and "/.build/" not in path.as_posix()
    )
    usage = {
        "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|@AppStorage\b",
        "NSPrivacyAccessedAPICategoryFileTimestamp": (
            r"\bcreationDate\b|\bmodificationDate\b|contentModificationDate|contentAccessDate|creationDateKey"
            r"|fileModificationDate|fileCreationDate|\bf?stat\("
        ),
        "NSPrivacyAccessedAPICategoryDiskSpace": (
            r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize\b|attributesOfFileSystem|statv?fs\("
        ),
        "NSPrivacyAccessedAPICategorySystemBootTime": r"\bsystemUptime\b|mach_absolute_time|mach_continuous_time",
        "NSPrivacyAccessedAPICategoryActiveKeyboards": r"activeInputModes",
    }
    for category, pattern in usage.items():
        if re.search(pattern, sources) and category not in declared:
            fail(f"PrivacyInfo.xcprivacy: the code uses a required-reason API but {category} is not declared")

    catalog = RESOURCES / "Localizable.xcstrings"
    try:
        strings = json.loads(catalog.read_text(encoding="utf-8"))
        if strings.get("sourceLanguage") != "en" or not isinstance(strings.get("strings"), dict):
            fail(f"{rel(catalog)}: expected sourceLanguage \"en\" and a \"strings\" dictionary")
    except (OSError, ValueError) as error:
        fail(f"{rel(catalog)}: {error}")


def main() -> int:
    urls = check_listing()
    check_consistency(urls)
    check_project()
    check_assets()
    check_privacy_manifest()

    for message in errors:
        print(f"error: {message}", file=sys.stderr)
    if errors:
        print(f"\n{len(errors)} problem(s) found.", file=sys.stderr)
        return 1

    print("App Store metadata and release configuration look good:")
    for locale in LOCALES:
        counts = ", ".join(
            f"{name.removesuffix('.txt')} {len((METADATA / locale / name).read_text(encoding='utf-8').strip())}/{limit}"
            for name, limit in LOCALIZED_LIMITS.items()
        )
        print(f"  {locale}: {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
