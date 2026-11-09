---
title: Jellyamp Privacy Policy
permalink: /privacy/
---

# Jellyamp Privacy Policy

*Effective 9 November 2026. [Deutsche Fassung](#deutsch) below.*

Jellyamp is a music player for iPhone and iPad that plays music from a
Jellyfin server you choose. This policy covers the Jellyamp app.

## The short version

- The developer of Jellyamp collects **no data** about you. There are no
  accounts with the developer, no analytics, no advertising, no tracking and
  no third-party SDKs in the app.
- The app sends data only to **servers you set up yourself**: your Jellyfin
  server and, if you use one, your own jellyamp-server.
- Scrobbling to **Last.fm** or **ListenBrainz** is off by default. If you
  switch it on, the app sends your listening history to the service you
  chose, and to nobody else.

## What the app sends, and where

### Your Jellyfin server

To sign in, browse and play, the app sends your Jellyfin server:

- your user name and password (or a Quick Connect code) when you sign in;
- an access token on every later request;
- a device name, an app-generated random device ID and the app version, which
  Jellyfin uses to list your sessions;
- what you browse, search, play, favourite and rate, and your playback
  progress, so play counts and "continue listening" work on the server.

This goes to the address you typed in and nowhere else. Whoever runs that
server decides what is stored there and for how long. If you enter an
`http://` address, the connection is not encrypted; use `https://` when the
server is reachable over the internet.

### Your jellyamp-server (optional)

If you enter the address of a jellyamp-server, the app sends it your API key
and the IDs of tracks to get similar tracks and mixes. It is software you or
someone you trust runs; the developer operates no such server.

### Last.fm and ListenBrainz (optional, off by default)

If you connect an account in Settings, the app sends the artist, title, album,
duration and time of the tracks you play to that service, with your account
token. Each service handles that data under its own policy:
[Last.fm](https://www.last.fm/legal/privacy),
[ListenBrainz / MetaBrainz](https://metabrainz.org/privacy). Disconnect the
account in Settings to stop. Listens that were already sent can be deleted in
your account at that service.

## What stays on your device

- Server address, user name and settings, in the app's preferences.
- Access tokens and API keys, in the iOS Keychain.
- A cache of your library and artwork, and the music you download for offline
  listening.

Signing out removes the stored sign-in. Deleting the app removes everything
else. Jellyamp does not read your contacts, photos, location, microphone or
Apple Music library.

## Apple

If you agreed to share analytics with app developers in iOS Settings, Apple
may give the developer anonymous crash and usage statistics for the app.
That is collected by Apple under
[Apple's privacy policy](https://www.apple.com/legal/privacy/), not by the
app. Requests you make through Siri or Shortcuts are handled by Apple.

## Children

Jellyamp is a general-purpose player and collects no data from anyone,
including children.

## Your rights

The developer holds no personal data about you, so there is nothing to
access, correct or delete on the developer's side. For data on your Jellyfin
server, ask whoever runs it. For scrobbles, use your Last.fm or ListenBrainz
account.

## Changes

Changes to this policy are published on this page, with a new date at the
top. The full history is public in the
[project repository](https://github.com/DJTobi24/jellyamp/commits/main/docs/PRIVACY.md).

## Contact

Questions about this policy: open an issue at
<https://github.com/DJTobi24/jellyamp/issues>. Issues are public, so do not
put personal data in them.

---

<a id="deutsch"></a>

# Datenschutzerklärung (Deutsch)

*Stand: 9. November 2026. Bei Abweichungen gilt die englische Fassung oben.*

Jellyamp ist ein Musikplayer für iPhone und iPad, der Musik von einem
Jellyfin-Server abspielt, den du selbst auswählst.

## Kurz gesagt

- Der Entwickler von Jellyamp erhebt **keine Daten** über dich. Es gibt kein
  Konto beim Entwickler, keine Analyse, keine Werbung, kein Tracking und keine
  SDKs von Dritten in der App.
- Die App sendet Daten nur an **Server, die du selbst einrichtest**: deinen
  Jellyfin-Server und, falls du einen nutzt, deinen eigenen jellyamp-server.
- Scrobbling zu **Last.fm** oder **ListenBrainz** ist standardmäßig aus. Wenn
  du es einschaltest, sendet die App deinen Hörverlauf an den gewählten Dienst
  und an niemanden sonst.

## Was die App wohin sendet

**Dein Jellyfin-Server.** Zum Anmelden, Stöbern und Abspielen sendet die App
deinem Server: Benutzername und Passwort (oder einen Quick-Connect-Code) bei
der Anmeldung, danach ein Zugriffstoken; einen Gerätenamen, eine von der App
zufällig erzeugte Geräte-ID und die App-Version; außerdem, was du durchsuchst,
abspielst, favorisierst und bewertest, sowie den Wiedergabefortschritt. Diese
Daten gehen ausschließlich an die Adresse, die du eingegeben hast. Was dort
wie lange gespeichert wird, bestimmt, wer den Server betreibt. Bei einer
`http://`-Adresse ist die Verbindung unverschlüsselt; nutze `https://`, wenn
der Server über das Internet erreichbar ist.

**Dein jellyamp-server (optional).** Wenn du die Adresse eines
jellyamp-servers einträgst, sendet die App ihm deinen API-Schlüssel und
Titel-IDs, um ähnliche Titel und Mixe zu erhalten. Der Entwickler betreibt
keinen solchen Server.

**Last.fm und ListenBrainz (optional, standardmäßig aus).** Wenn du in den
Einstellungen ein Konto verbindest, sendet die App Interpret, Titel, Album,
Dauer und Zeitpunkt der gespielten Titel zusammen mit deinem Konto-Token an
diesen Dienst. Es gelten die Datenschutzbestimmungen von
[Last.fm](https://www.last.fm/legal/privacy) bzw.
[ListenBrainz / MetaBrainz](https://metabrainz.org/privacy). Trenne das Konto
in den Einstellungen, um das Senden zu beenden.

## Was auf deinem Gerät bleibt

Serveradresse, Benutzername und Einstellungen; Zugriffstoken und API-Schlüssel
im iOS-Schlüsselbund; ein Zwischenspeicher deiner Mediathek und Cover sowie
die Musik, die du für die Offline-Wiedergabe lädst. Abmelden entfernt die
gespeicherte Anmeldung, das Löschen der App alles Übrige. Jellyamp greift
nicht auf Kontakte, Fotos, Standort, Mikrofon oder deine
Apple-Music-Mediathek zu.

## Apple

Wenn du in den iOS-Einstellungen zugestimmt hast, Analysedaten mit
App-Entwicklern zu teilen, kann Apple dem Entwickler anonyme Absturz- und
Nutzungsstatistiken bereitstellen. Diese erhebt Apple nach der
[Apple-Datenschutzrichtlinie](https://www.apple.com/de/legal/privacy/), nicht
die App. Anfragen über Siri oder Kurzbefehle verarbeitet Apple.

## Deine Rechte

Der Entwickler speichert keine personenbezogenen Daten über dich; es gibt bei
ihm also nichts auszukunften, zu berichtigen oder zu löschen. Für Daten auf
deinem Jellyfin-Server wende dich an dessen Betreiber, für Scrobbles an dein
Last.fm- oder ListenBrainz-Konto.

## Kontakt

Fragen zu dieser Erklärung: Erstelle ein Issue unter
<https://github.com/DJTobi24/jellyamp/issues>. Issues sind öffentlich, schreibe
dort keine personenbezogenen Daten hinein.
