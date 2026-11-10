# Localization

Jellyamp ships in **English** (development language) and **German**. This
page says where the strings live, how to add one without a Mac, and which
German words to use so the app stays consistent.

## Where the strings are

| File | Holds |
|---|---|
| `ios/Jellyamp/Resources/Localizable.xcstrings` | Every UI string, Siri dialog and App Intent title. Keyed by the English text. |
| `ios/Jellyamp/Resources/InfoPlist.xcstrings` | App name and the local-network permission text. |
| `ios/Jellyamp/Resources/{en,de}.lproj/AppShortcuts.strings` | The spoken App Shortcut phrases ("Play music in Jellyamp") and the titles of their tiles. |
| `ios/Jellyamp/Localization/CoreLocalization.swift` | Hands localized text to `JellyampCore` (see below). |
| `ios/fastlane/metadata/{en-US,de-DE}` | App Store listing (separate from the app, see `docs/RELEASE.md`). |

XcodeGen picks all of these up from the `Resources` folder and adds `de` to
the project's known regions on its own; `ios/project.yml` only repeats the
languages in `CFBundleLocalizations`.

## Adding or changing a string

1. Write the English text as a SwiftUI literal (`Text("…")`,
   `Label("…", systemImage:)`, `.navigationTitle("…")`, …) or, outside views,
   as `String(localized: "…")`.
2. Add the key to `Localizable.xcstrings` with its German text:

   ```json
   "Clear Up Next" : {
     "localizations" : {
       "de" : { "stringUnit" : { "state" : "translated", "value" : "„Als Nächstes“ leeren" } }
     }
   },
   ```

3. Run `python3 scripts/check-localization.py`. It lists keys the code uses
   that the catalog lacks, stale catalog keys, and translations whose
   placeholders do not match. CI runs it in the "App Store metadata" job.

On a Mac, Xcode adds new keys to the catalog on every build
(`SWIFT_EMIT_LOC_STRINGS`); translate them in the catalog editor and commit.

### Keys with values in them

The key is the English text with each `\(…)` replaced by a format specifier:
`%lld` for an `Int`, `%@` for a `String`, `%lf` for a `Double`.
`Text("\(count) of \(total)")` looks up `%lld of %lld`. The check script
cannot infer Swift types; it knows the common cases (`.count`, `.title`,
`.formatted()`) and otherwise reads the table `INTERPOLATION_TYPES` at the
top of the script. A new interpolated expression that is in neither is
reported as an error — add it to the table with the type you see in the
code.

The translation repeats the specifiers with their position, so German can
reorder them: `%1$@ von %2$@`.

### Counts

Never write `"\(n) songs"` and hope: give the key plural forms.

- One number in the string: `variations.plural` with `one` and `other`, for
  English *and* German (see `%lld songs` in the catalog).
- Several values: a substitution for the counted one (see
  `%lld of %lld songs downloaded`, where the second number picks
  "Titel"/"Titeln").

### Pitfalls the script cannot catch

- **A `String` handed to `Text` is never translated.** `Text(title)` with
  `let title: String` shows the text as is. Either the value comes from
  `String(localized:)`, or the parameter is a `LocalizedStringKey` (as in
  `ContentUnavailableCompatView(title:systemImage:description:)`,
  `HomeShelf`, `AboutLinkRow`). The script understands parameters typed
  `LocalizedStringKey`/`LocalizedStringResource` and finds their call sites,
  but it cannot tell that a `String` parameter should have been one.
  `python3 scripts/check-localization.py --strays` prints the literals it
  did not treat as keys, as a review aid.
- **`cond ? "Text" : someString` is a `String`.** Both branches must be
  literals for SwiftUI to localize them; the script reports the mixed form.
- **Do not localize** log messages, identifiers, URLs, example addresses, or
  anything that comes from the server (titles, artist names, genre names,
  error text Last.fm sends back).
- **Do not pass a year through `%lld`** in a string that is not a count;
  format it as text first (see the decade titles in `CoreLocalization.swift`).

## Text composed in the packages

`JellyampCore`, `JellyfinBackend` and `SonicClient` build and test on Linux
and carry no resource bundles, so they cannot look anything up. Two structs
hold the English defaults for the text Core composes itself, and the app
shell replaces them with catalog strings:

- `CoreStrings` (`JellyampCore/Localization/CoreStrings.swift`): "3 songs",
  "1 hr 12 min", VoiceOver durations, "Track 3", station titles ("Library
  Radio", "1980s"), fixed scrobbling errors. `JellyampApp.init` installs
  `CoreStrings.localized` before any UI exists.
- `CarPlayStrings`: the CarPlay lists; `CarPlaySceneDelegate` passes
  `CarPlayStrings.localized`.

A new user-visible phrase in a package gets a field in one of these structs
(English default, used by the package tests) and a line in the `localized`
extension. Things the UI can decide itself stay out of the packages: the EQ
preset names are mapped by ID in `EQPreset.localizedName`, errors are turned
into sentences in `LibraryErrorText`, `SignInErrorMessage`,
`DownloadFormatting` and `OfflineErrorMessage`.

Station seeds, sort keys and other values sent to a server are never
translated (`Decade.seed` stays `"1980s"`; only `Decade.title` is localized).

## App Shortcut phrases

Siri only offers App Shortcuts in languages that have phrases. They live in
`de.lproj/AppShortcuts.strings`, keyed by the English phrase from
`JellyampShortcuts.swift` with `\(.applicationName)` written as
`${applicationName}` and a parameter `\(\.$target)` as `${target}`:

```
"Play ${target} in ${applicationName}" = "Spiele ${target} in ${applicationName}";
```

Every German phrase must contain `${applicationName}` and the same parameter
as its key; the check script enforces that and that every phrase in the code
has a translation. `en.lproj/AppShortcuts.strings` maps each key to itself
(it exists so the project has a base table for the German one). The tile
titles (`shortTitle:`) are listed in these files and in
`Localizable.xcstrings`.

This is the `.strings` format App Shortcuts have used since iOS 16. Xcode can
convert it to an `AppShortcuts.xcstrings` catalog (right-click → *Migrate to
String Catalog*) once someone has a Mac at hand.

## German glossary

Informal address ("du"), short labels, standard iOS wording. The App Store
text in `ios/fastlane/metadata/de-DE` uses the same vocabulary.

| English | German | Note |
|---|---|---|
| Library | Bibliothek | |
| Home (tab) | Start | |
| Search | Suchen | |
| Settings | Einstellungen | |
| Song, Track | Titel | singular = plural; dative plural "Titeln" |
| Album / Albums | Album / Alben | |
| Artist | Interpret | |
| Playlist | Playlist | |
| Liked Songs | Lieblingstitel | |
| Saved Albums | Gespeicherte Alben | "Album speichern" |
| Following | Gefolgte Interpreten | Follow → Folgen |
| Favorite | Favorit | the heart button |
| Recently Added / Played | Zuletzt hinzugefügt / gehört | |
| Jump Back In | Weiterhören | |
| Play | Wiedergabe | button label, as in Apple Music |
| Shuffle | Zufällig | |
| Repeat | Wiederholen | |
| Play Next | Als Nächstes spielen | |
| Up Next | Als Nächstes | |
| Queue | Warteschlange | |
| Now Playing | Jetzt läuft | |
| Lyrics | Songtext | |
| Sleep Timer | Sleep-Timer | |
| Download (verb) | Laden | "Geladen", "Wird geladen" |
| Downloads | Downloads | the tab and the files |
| Offline Mode | Offline-Modus | |
| Cellular | Mobile Daten | |
| Wi-Fi | WLAN | |
| Crossfade | Überblenden | |
| Loudness Leveling | Lautstärkeanpassung | |
| Preamp | Vorverstärkung | |
| Autoplay | Automatische Wiedergabe | |
| Station | Sender | "Genresender", "Jahrzehntsender" |
| Radio | Radio | "Interpretenradio", "Titelradio", "Bibliotheksradio" |
| Mix / Mixes for You | Mix / Mixe für dich | |
| Instant Mix | Sofort-Mix | |
| Time Travel | Zeitreise | |
| sonic server | Sonic-Server | "sonically similar" → "klanglich ähnlich" |
| Scrobbling | Scrobbeln | a queued "listen" → Scrobble |
| Sign In / Out | Anmelden / Abmelden | |
| Account | Account | |
| Save (button) | Sichern | |
| API key | API-Schlüssel | |
| Jellyfin fallback | Jellyfin-Fallback | |
| About | Info | |

Not translated: Jellyamp, Jellyfin, jellyamp-server, Quick Connect, Last.fm,
ListenBrainz, CarPlay, AirPlay, Sonic Adventure, Smart Sync, the quality
badges HI-RES / LOSSLESS, the EQ presets Rock, Electronic, Hip-Hop and
Loudness, and technical units (kbps, dB, kHz). Quoted names use „…“.
Ellipses in German labels take a space before them ("Wird geladen …").
