# ADR-0001: Generate the Xcode project with XcodeGen

## Status
Accepted

## Context
Development happens partly in a Linux container without Xcode. A checked-in
`.xcodeproj` cannot be authored or merged reliably (opaque pbxproj UUIDs).
Tuist manifests are Swift code that must be executed by Tuist on macOS even to
validate, and its caching/signing machinery is overkill for one app target.

## Decision
Describe the project in `ios/project.yml` (XcodeGen, declarative YAML) and
gitignore `*.xcodeproj`. Developers run `xcodegen generate` once per checkout
on macOS; CI does the same on the macOS runner.

## Consequences
- Project definition is reviewable/diffable and editable on Linux.
- App code must tolerate not being compiled until a macOS session; mitigated
  by keeping ~80% of logic in SPM packages that build on Linux.
