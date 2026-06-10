# ADR-0003: GRDB (SQLite) for persistence

## Status
Accepted

## Context
The app needs a local metadata cache synced in bulk from Jellyfin (tens of
thousands of rows), instant full-text search, and a download state machine.
SwiftData requires iOS 17 and is weak at bulk upserts; CoreData is clumsy for
bulk sync and untestable off-macOS.

## Decision
Use GRDB.swift: plain SQL migrations, fast bulk writes, FTS5 full-text search.
Store *protocols* (`MetadataStoring`, `DownloadStoring`, `SettingsStoring`)
live in `JellyampCore` with in-memory fakes; GRDB implementations live in the
app shell.

## Consequences
- Library sync and search stay fast at large library sizes.
- Core logic tests run on Linux against fakes; GRDB-specific tests run in the
  macOS CI job.
