---
title: Jellyamp Help & Support
permalink: /support/
---

# Jellyamp Help & Support

Jellyamp plays music from your own [Jellyfin](https://jellyfin.org) server.
It contains no music and is not a streaming service.

## Get help

- **Something is broken or missing:** open an issue at
  <https://github.com/DJTobi24/jellyamp/issues>. Include your Jellyamp version
  (Settings → About), iOS version and Jellyfin server version, and the steps
  that lead to the problem. Issues are public: leave out passwords, tokens
  and server addresses you want to keep private.
- **Questions about Jellyfin itself** (installing a server, adding a music
  library, remote access): see the
  [Jellyfin documentation](https://jellyfin.org/docs/).

Jellyamp is a spare-time open-source project. Issues are answered as time
allows.

## Before you start

You need:

1. A Jellyfin server, version 10.9 or newer, with a music library.
2. A user account on that server.
3. A network path from your iPhone or iPad to the server: the same Wi-Fi, a
   VPN, or a public HTTPS address.

Just want to look around? Sign in to Jellyfin's public demo server: address
`https://demo.jellyfin.org/stable`, user name `demo`, leave the password
empty.

## Common problems

### "Could not connect to the server"

- Type the full address including the port, for example
  `http://192.168.1.20:8096` or `https://jellyfin.example.com`.
- Open the same address in Safari on the same device. If the Jellyfin web
  page does not load there, the app cannot reach the server either.
- The first time you connect to a server on your home network, iOS asks
  whether Jellyamp may find devices on your local network. If you tapped
  "Don't Allow", turn it on in iOS Settings → Privacy & Security → Local
  Network → Jellyamp.
- Away from home, a `192.168.…` or `.local` address only works through a VPN.
- For `https://` addresses the certificate must be trusted by iOS.
  Self-signed certificates are rejected.

### Music stops when the screen locks or after a while in the background

- Check that Low Data Mode or a VPN is not cutting the connection.
- Download the album or playlist for offline listening when the connection is
  unreliable.

### A track does not play, or playback starts late

Jellyamp plays MP3, AAC, ALAC, FLAC and other formats iOS supports directly
and asks the server to convert the rest. Converting needs a working FFmpeg on
the server; check the server log if only some formats fail.

### Lyrics are missing

Lyrics come from your Jellyfin server. Add `.lrc` files next to your tracks
or install a lyrics plugin on the server, then rescan the library.

### "Sonic" features are missing

Sonic Adventure, sonically similar tracks and Mixes for You need the optional
jellyamp-server next to your Jellyfin server. Without it, Jellyamp uses
Jellyfin's built-in Instant Mix. Setup instructions are in the
[project README](https://github.com/DJTobi24/jellyamp#readme).

### Scrobbles do not show up

Open Settings → Scrobbling and check that the account is still connected.
Listens made offline are sent the next time the app is online.

## Delete your data

Settings → Sign Out removes the stored sign-in. Deleting the app removes
downloads, caches and settings. The developer stores nothing about you; see
the [privacy policy](../privacy/).

---

Jellyamp is an independent open-source project. It is not affiliated with,
endorsed by or sponsored by Jellyfin or Plex.
