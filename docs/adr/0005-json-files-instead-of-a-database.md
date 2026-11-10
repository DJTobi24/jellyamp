# ADR-0005: No local database — JSON files, Keychain and UserDefaults

## Status
Accepted for 1.0. Supersedes [ADR-0003](0003-grdb-over-swiftdata.md).

## Context
ADR-0003 planned a GRDB/SQLite store in the app: a full metadata mirror of
the Jellyfin library, FTS5 search, a download table and play history. None of
it was built. While the app grew, each need was met without it:

- **Browsing** pages straight from the server (`LibraryBrowseAPI`,
  `PagedLoader`), with sorting and filtering done by Jellyfin. A mirror would
  have to be synced with the server and kept from going stale.
- **Search** is Jellyfin's `searchTerm=`; results are ranked in
  `SearchRanker`.
- **Offline** needs only what is downloaded. That set is small, and each
  downloaded track carries its metadata in the `DownloadIndex`, from which
  `OfflineCatalog` rebuilds albums, artists, genres, playlists and search in
  memory.
- **Play history** lives on the server (playback reports).

GRDB was the app's only third-party dependency and it was unused, so it was
removed from `ios/project.yml`.

## Decision
The app keeps no database. Persistent state is:

- `AppSettings` as JSON in UserDefaults (`UserDefaultsSettingsStore`);
- secrets in the Keychain (`KeychainCredentialStore`);
- the `DownloadIndex` as one schema-versioned JSON file next to the
  downloaded audio;
- `BoundedJSONCache` files for first pages of lists and Home shelves — a
  cache with expiry and size limits, never a source of truth;
- small JSON files for the scrobble queue and measured loudness.

The rules for every one of these (index transitions, cache limits, queue
policy, tolerant settings decoding) are plain Swift in `JellyampCore` and are
unit-tested on Linux. The app shell only reads and writes the files.

## Consequences
- No migrations, no third-party code in the app, and persistence logic is
  tested without a simulator.
- Without a network connection only downloaded music can be browsed and
  searched. That is the intended offline model.
- Search quality is Jellyfin's: it matches item names only, so a track is not
  found by its artist's name (see `JELLYFIN-API-NOTES.md`).
- The download index is rewritten as a whole on every change. That is fine
  for thousands of tracks; a library-sized offline collection would be the
  point to revisit this decision.
- `MetadataStoring` and `DownloadStoring` in
  `JellyampCore/Stores/StoreProtocols.swift` are leftovers of the GRDB plan
  with no implementation; only `SettingsStoring` is in use.
