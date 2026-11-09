# Scrobbling (Last.fm & ListenBrainz)

Both services are optional and off by default. Everything except the thin
adapter lives in `JellyampCore/Scrobbling` and is unit-tested on Linux with
canned HTTP responses.

```
PlayerStateModel ──▶ ScrobbleService ──▶ ScrobbleCoordinator   (when does a play count?)
  track / isPlaying /   (app shell)   └─▶ ScrobbleEngine        (queue, retries, delivery)
  currentTime                              ├─▶ ListenBrainzScrobbleTarget ─▶ ListenBrainzClient
                                           └─▶ LastFMScrobbleTarget ──────▶ LastFMClient
```

## Rules

- **Now playing** is sent when a track starts producing audio (and again
  after a pause of more than 30 s). It is best effort and never queued.
- **A scrobble** is sent once per play, as soon as the track — which must be
  longer than 30 s — has been *played* for half its length or 4 minutes.
  Played time is measured (position advancing in step with the clock), so
  seeking forward does not count; pauses and stalls do not count either.
- Repeat-one counts every play: a jump from the end of the track back to its
  start begins a new play with a new timestamp.
- The timestamp of a scrobble is the start of the play.

## Offline queue

Every scrobble is written to `Application Support/Scrobbling/queue.json`
before delivery and removed only when its service accepted it. One entry per
listen and service; duplicates (same track, same start second) are ignored.
Flushes run oldest first, in batches (Last.fm 50, ListenBrainz 1000), on
every new scrobble, when the app becomes active and when the network returns.

| Answer from the service | What happens |
|---|---|
| no connection | kept, attempt not counted |
| rate limit / 5xx / Last.fm 8, 11, 16, 29 | kept, attempt counted, service left alone until the delay passed |
| token / session refused (ListenBrainz 401, Last.fm 9) | credential deleted, user asked to reconnect, listens keep queueing |
| payload refused (400, Last.fm 6, …) | dropped — it would block the queue forever |

Entries are dropped after 14 days (Last.fm refuses older scrobbles) or 12
counted attempts; the queue holds at most 2000 entries.

## Last.fm API key

Last.fm needs a per-app API key and shared secret
(<https://www.last.fm/api/account/create>). They are **not committed**:

1. `cp ios/Config/Signing.xcconfig.example ios/Config/Signing.xcconfig`
   (gitignored) and fill in `LASTFM_API_KEY` / `LASTFM_API_SECRET`; on CI pass
   them as `xcodebuild … LASTFM_API_KEY=… LASTFM_API_SECRET=…`.
2. `project.yml` maps the build settings to the Info.plist keys
   `LastFMAPIKey` / `LastFMAPISecret`, read by `LastFMConfiguration`.

A build without them works; Settings → Scrobbling then shows "Last.fm is not
available in this build" instead of the Connect button.

The shared secret ends up inside the app binary and can be extracted from
it. That is inherent to Last.fm's API and the accepted norm for desktop and
mobile scrobblers: the secret only identifies the app, it gives no access to
any user account (that needs the per-user session key, which is stored in the
Keychain). If the key is abused, Last.fm can suspend it and a new one is
issued with an app update.

Sign-in uses the token flow for native apps: `auth.getToken` → the user
approves at `https://www.last.fm/api/auth/?api_key=…&token=…` inside an
`ASWebAuthenticationSession` and closes the sheet → `auth.getSession`. Requests
are signed with the MD5 of the name-sorted parameters plus the secret; the
MD5 is a small pure-Swift implementation (`MD5.swift`) because CryptoKit does
not exist on Linux.

## ListenBrainz

The user pastes their token from <https://listenbrainz.org/settings/>; it is
checked with `GET /1/validate-token` and stored in the Keychain. An optional
server URL supports self-hosted ListenBrainz-compatible APIs. Listens carry
`additional_info` with `media_player` / `submission_client` = `Jellyamp`,
`submission_client_version`, `duration_ms` and `tracknumber`.

## Privacy

Nothing is sent unless the user connects an account and leaves its toggle on.
Signing out of Jellyfin disconnects both accounts and clears the queue.
