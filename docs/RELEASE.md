# Releasing Jellyamp: from zero to "Waiting for Review"

Everything that can live in the repository already does: signing setup,
icon, privacy manifest, listing texts in English and German, review notes,
fastlane lanes and CI. What is left are the steps only the account holder can
do. Follow them in order.

## Kurzfassung (Deutsch)

Du brauchst einen Mac mit Xcode 26, einen bezahlten Apple-Developer-Account
(99 USD/Jahr) und etwa einen Nachmittag. Danach in dieser Reihenfolge:

1. **Developer Program** beitreten (Schritt 1). Als Einzelperson erscheint
   dein bürgerlicher Name im App Store.
2. **App-ID** `dev.djtobi.jellyamp` anlegen (Schritt 2) und den **App-Eintrag**
   in App Store Connect erstellen (Schritt 3). Ist der Name „Jellyamp“
   vergeben, nimm „Jellyamp for Jellyfin“.
3. **API-Key** (Rolle Admin) erzeugen und die `.p8`-Datei sicher ablegen
   (Schritt 4).
4. `ios/Config/Signing.xcconfig` aus der `.example`-Datei kopieren und deine
   Team-ID eintragen (Schritt 5). Die Datei wird nicht eingecheckt.
5. Lokal bauen und nach TestFlight laden: `bundle exec fastlane beta`
   (Schritte 6–7). Für CI die vier Secrets setzen; danach reicht ein Tag
   `v1.0.0`.
6. Auf einem echten Gerät testen, **vor allem die Anmeldung am Demo-Server**
   aus den Review-Notizen (Schritt 8).
7. **GitHub Pages** für `/docs` einschalten, damit Datenschutz- und
   Support-Seite erreichbar sind (Schritt 9).
8. **Screenshots** erstellen: iPhone 6,9" und iPad 13" (Schritt 10). Keine
   urheberrechtlich geschützten Cover zeigen.
9. `bundle exec fastlane release` lädt Texte und Screenshots hoch
   (Schritt 11). In App Store Connect von Hand beantworten (Schritt 12):
   Datenschutz „Keine Daten erfasst“, Altersfreigabe (alles „Nein“ → 4+),
   Verschlüsselung „Nein“, Inhaltsrechte „Nein“, DSA-Händlerstatus, Preis
   „Kostenlos“.
10. Kontaktdaten für das Review eintragen, Build auswählen, **Zur Prüfung
    einreichen** (Schritt 13).

Die Begründungen für App Review (HTTP-Verbindungen, Hintergrund-Audio,
Demo-Zugang) stehen fertig in
`ios/fastlane/metadata/review_information/notes.txt`. Typische
Ablehnungsgründe und was dieses Projekt dagegen tut: Abschnitt
[Common rejections](#common-rejections-for-media-server-clients).

Kein Rechtsrat: Ob du als „Händler“ im Sinne des DSA giltst und ob du ein
Impressum brauchst, musst du selbst klären (Schritt 12.6).

---

## What is already done

| Topic | Where |
|---|---|
| Bundle ID, version, build number, signing style | `ios/project.yml` |
| Team ID and optional Last.fm keys, kept out of git | `ios/Config/Signing.xcconfig` (from `.example`) |
| App icon (default, dark, tinted), accent colour, launch colour | `ios/Jellyamp/Resources/Assets.xcassets`, regenerate with `scripts/generate-app-icon.py` |
| Privacy manifest | `ios/Jellyamp/Resources/PrivacyInfo.xcprivacy` |
| Export compliance, ATS, background audio, orientations | `ios/project.yml` → Info.plist |
| Listing texts (en-US, de-DE), review notes, age rating | `ios/fastlane/metadata/` |
| Privacy policy, support page, landing page | `docs/PRIVACY.md`, `docs/SUPPORT.md`, `docs/index.md` (GitHub Pages) |
| Build, upload, metadata lanes | `ios/fastlane/Fastfile` |
| PR gate: build, unit tests, unsigned Release archive, metadata check | `.github/workflows/ios.yml` |
| TestFlight upload from CI | `.github/workflows/release-testflight.yml` |

`python3 scripts/check-appstore-metadata.py` verifies text limits, the icon
format, the privacy manifest and the release-critical settings. CI runs it on
every push.

## What you need

- A Mac with Xcode 26 (the app uses the iOS 26 SDK; it still runs on iOS 16).
- `brew install xcodegen`
- Ruby 3.2 or newer with Bundler: `cd ios && bundle install`
- An iPhone for testing. Audio in the background, the lock screen and AirPlay
  cannot be judged in the simulator.

---

## Step 1: Join the Apple Developer Program

1. Go to <https://developer.apple.com/programs/enroll/> or use the Apple
   Developer app. Sign in with the Apple Account you want to own the app;
   it needs two-factor authentication.
2. Choose **Individual** unless you publish as a company. As an individual,
   your legal name is the seller name on the App Store. An organisation needs
   a D-U-N-S number and takes days longer.
3. Pay the yearly fee (99 USD or the local equivalent). Approval usually
   takes up to 48 hours.
4. In [App Store Connect](https://appstoreconnect.apple.com) → **Business**,
   accept the **Free Apps Agreement**. A free app needs no banking or tax
   forms.

## Step 2: Register the App ID

1. <https://developer.apple.com/account/resources/identifiers/list> → **+** →
   **App IDs** → **App**.
2. Description: `Jellyamp`. Bundle ID: **Explicit**, `dev.djtobi.jellyamp`.
   It must equal `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` and can
   never be changed after the first upload.
3. Capabilities: tick **nothing**. Background audio is an Info.plist key, not
   an App ID capability. Siri is not needed for App Intents and Shortcuts.
   CarPlay comes later (appendix A).
4. **Continue** → **Register**.

## Step 3: Create the App Store Connect record

1. App Store Connect → **Apps** → **+** → **New App**.
2. Platform **iOS**. Name `Jellyamp`. Primary language **English (U.S.)**.
   Bundle ID: the one from step 2. SKU: `jellyamp-ios`. User access: Full.
3. App names are unique across the store. If `Jellyamp` is taken, use
   `Jellyamp for Jellyfin` (21 characters) and put the same text in
   `ios/fastlane/metadata/*/name.txt`.

## Step 4: Create an App Store Connect API key

fastlane and CI sign in with an API key, never with your Apple ID.

1. App Store Connect → **Users and Access** → **Integrations** →
   **App Store Connect API** → **Team Keys** → **+**. The first time, the
   account holder has to request API access on that page.
2. Name `jellyamp-ci`, access **Admin**. Admin is what lets `xcodebuild`
   create signing certificates and provisioning profiles for you. A key with
   the App Manager role can upload builds and edit the listing but fails at
   the signing step.
3. Download `AuthKey_XXXXXXXXXX.p8`. It can be downloaded **once**. Keep it in
   your password manager, outside the repository (`*.p8` is gitignored as a
   safety net).
4. Note the **Key ID** (10 characters) and the **Issuer ID** (a UUID above the
   table).

## Step 5: Local signing configuration

```sh
cd ios
cp Config/Signing.xcconfig.example Config/Signing.xcconfig
```

Edit `Config/Signing.xcconfig` and set `DEVELOPMENT_TEAM` to your Team ID
(<https://developer.apple.com/account> → Membership details). The file is
gitignored. `Config/Jellyamp.xcconfig` includes it when it exists, so a
checkout without it (CI, contributors) still builds for the simulator.

Optional: put Last.fm application keys in the same file to enable Last.fm
scrobbling. They reach the app through Info.plist (`LastFMAPIKey`,
`LastFMAPISecret`). A client app's Last.fm "secret" is extractable from the
binary by anyone, so do not reuse it elsewhere.

## Step 6: First archive on your Mac

Do this once by hand. It shows signing problems in Xcode, where they are
easy to read.

```sh
cd ios
xcodegen generate
open Jellyamp.xcodeproj
```

1. Xcode → Settings → Accounts: add your Apple Account.
2. Target **Jellyamp** → Signing & Capabilities: the team is filled in from
   the xcconfig and "Automatically manage signing" is on. There must be no
   red error.
3. Run on your iPhone and play something (step 8 has the checklist).
4. Destination **Any iOS Device (arm64)** → Product → **Archive**.
5. In the Organizer: **Validate App**. Fix what it reports before going on.

## Step 7: Upload to TestFlight

### From your Mac

```sh
cd ios
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_CONTENT="$(cat ~/keys/AuthKey_XXXXXXXXXX.p8)"
bundle exec fastlane beta
```

The lane generates the project, asks TestFlight for the latest build number
and adds one, archives the Release configuration with automatic signing,
exports an App Store `.ipa` to `ios/build/` and uploads it. The "What to
Test" text is the list of commits since the previous `v*` tag. Processing at
Apple takes 5 to 30 minutes; the lane waits for it so it can attach that
text. Set `TESTFLIGHT_SKIP_WAITING=1` to return right after the upload.

Other lanes: `fastlane test` (unit tests on a simulator), `fastlane build`
(build the `.ipa` without uploading).

### From GitHub Actions

Add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `ASC_KEY_ID` | Key ID from step 4 |
| `ASC_ISSUER_ID` | Issuer ID from step 4 |
| `ASC_KEY_CONTENT` | Whole content of the `.p8` file, including the BEGIN/END lines |
| `DEVELOPMENT_TEAM` | Your Team ID |
| `LASTFM_API_KEY`, `LASTFM_API_SECRET` | Optional |

Then either run **Actions → TestFlight → Run workflow**, or push a tag that
matches `MARKETING_VERSION`:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

Know before you rely on it:

- Every CI run starts on a fresh machine, so Xcode creates a new Apple
  Development certificate through the API key each time. Apple caps the
  number of certificates per team. When a run fails with a certificate-limit
  error, revoke the old "Created via API" certificates at
  <https://developer.apple.com/account/resources/certificates/list>.
  Uploading from your Mac avoids this.
- The workflow has not run yet: it needs your secrets. Do the first upload
  from your Mac (above), then try the workflow.

### Testers

- **Internal testers** (up to 100 people who are users of your App Store
  Connect team): TestFlight → Internal Testing → create a group, add
  yourself. Builds are available minutes after processing, without review.
- **External testers** (up to 10,000, by email or public link) need a
  one-time Beta App Review. Fill in TestFlight → Test Information first:
  feedback email, a beta description, and under "Sign-in information" the
  demo server from the review notes. To send a build to external groups from
  the lane, set `TESTFLIGHT_GROUPS="Friends,Public"`.

## Step 8: Test the build like a reviewer

On a real iPhone, with the TestFlight build:

1. Delete any earlier install so you see the first-run experience.
2. Sign in to the **demo server exactly as the review notes describe**:
   `https://demo.jellyfin.org/stable`, user `demo`, empty password. If this
   does not work, the app will be rejected. See
   [the demo account](#the-demo-account) for the alternative.
3. Play an album; lock the phone; use the lock-screen controls; take a call
   or start a timer and check playback resumes.
4. Switch to a `http://` server on your LAN: the local-network prompt
   appears and playback works.
5. Rotate the phone. On an iPad: all four orientations, Split View and
   Slide Over.
6. Settings → About: version and build are right; the privacy and support
   links open (after step 9).
7. Check every feature the store description promises
   (`ios/fastlane/metadata/en-US/description.txt`). Delete the lines for
   anything that is not in this build. Guideline 2.3.1 forbids advertising
   features the app does not have.

## Step 9: Publish the privacy and support pages

The listing links to three pages that GitHub Pages serves from `docs/`:

| Page | URL | Source |
|---|---|---|
| Marketing URL | <https://djtobi24.github.io/jellyamp/> | `docs/index.md` |
| Privacy policy | <https://djtobi24.github.io/jellyamp/privacy/> | `docs/PRIVACY.md` |
| Support | <https://djtobi24.github.io/jellyamp/support/> | `docs/SUPPORT.md` |

1. Repository → Settings → **Pages** → Source **Deploy from a branch** →
   branch `main`, folder `/docs` → Save. Pages on a free plan needs a public
   repository.
2. Wait for the "pages build and deployment" action, then open all three
   URLs. App Review opens them too; a 404 is a rejection (guideline 1.5 /
   5.1.1).
3. Read `docs/PRIVACY.md` once and confirm it describes what the final app
   does. It is your statement, not boilerplate.

The same URLs are in `AboutView.swift` and `ios/fastlane/metadata/*/*_url.txt`.
If you move the pages, the metadata check fails until all three agree.

## Step 10: Screenshots

Required for a universal iPhone + iPad app in 2026:

| Set | Device to capture on | Pixels (portrait) |
|---|---|---|
| iPhone 6.9" | iPhone 17 Pro Max (or 16 Pro Max) | 1320 × 2868 (1290 × 2796 is also accepted) |
| iPad 13" | iPad Pro 13-inch | 2064 × 2752 (2048 × 2732 is also accepted) |

App Store Connect scales these down for every smaller device. Provide 3 to
10 per set and language; the first three show up in search results.

Rules that get screenshots rejected:

- **No copyrighted album covers, artist photos or lyrics.** Use the
  synthetic library from `scripts/dev-jellyfin/` (generated covers, made-up
  artists) or music you hold the rights to.
- Show the app in use, not the login screen or a splash screen.
- No device frames from other manufacturers, no "best", "#1" or prices, no
  mention of other platforms.

Suggested set: Now Playing with large artwork, album view, library/home,
synced lyrics, downloads, equalizer.

By hand: run the app in the two simulators, `Cmd+S` saves a screenshot at
the right size. Put the files here; fastlane detects the device from the
resolution:

```
ios/fastlane/screenshots/en-US/01-now-playing-iphone.png
ios/fastlane/screenshots/en-US/01-now-playing-ipad.png
ios/fastlane/screenshots/de-DE/…
```

Automated: `bundle exec fastlane screenshots` runs the screenshot UI tests on
whichever "Pro Max" iPhone and 13-inch iPad simulators are installed. It
needs the `JellyampUITests` target; until that exists the lane stops with a
message.

## Step 11: Upload the listing

```sh
cd ios
export REVIEW_FIRST_NAME=… REVIEW_LAST_NAME=… REVIEW_PHONE="+49 …" REVIEW_EMAIL=…
bundle exec fastlane release
```

(with the `ASC_*` variables from step 7). This uploads, for English and
German: name, subtitle, description, keywords, promotional text, release
notes, the three URLs, copyright, the primary category (Music), the review
notes and your reviewer contact details, plus the screenshots if there are
any. It **does not submit**. The contact details are read from the
environment so that your phone number is not committed.

`bundle exec fastlane release rating:true` also uploads the age rating from
`ios/fastlane/metadata/app_rating.json`.

## Step 12: Questions only you can answer in App Store Connect

### 12.1 App Privacy (the "nutrition label")

App → **App Privacy** → Get Started.

- "Do you or your third-party partners collect data from this app?" → **No**.
- Result: **Data Not Collected**.

Why this is the right answer: Apple defines "collect" as transmitting data
off the device in a way that lets *you or your partners* access it. Jellyamp
sends data only to the user's own Jellyfin server and, if the user turns
scrobbling on, to the user's own Last.fm or ListenBrainz account. You run
none of these and receive nothing. There is no analytics and no SDK. The
privacy manifest (`PrivacyInfo.xcprivacy`) says the same: no tracking, no
collected data types, and three required-reason APIs (UserDefaults `CA92.1`,
file timestamps `C617.1`, disk space `E174.1`).

If you ever add crash reporting or analytics, both the label and the
manifest must change first.

Privacy Policy URL: already uploaded by `fastlane release`.

### 12.2 Age rating

App Information → Age Rating. Answer **None / No** to every question:
no violence, sexual content, profanity, drugs, gambling, horror or medical
content; no unrestricted web access; no messaging or chat; no user-generated
content; no advertising; not made for kids. Result: **4+**.

The reasoning: the app ships no content. What a user plays comes from their
own library, the same as the built-in Files or Music apps playing a user's
files. "User-generated content" means content that users share with *other
users* through your app, which Jellyamp does not do. If App Review disagrees
and asks for a higher rating, accept it; it costs nothing.

### 12.3 Export compliance (encryption)

`ITSAppUsesNonExemptEncryption` is `false` in Info.plist, so App Store
Connect does not ask per build. If the question appears anyway: "Does your
app use encryption?" → the app uses **only** encryption that is part of
Apple's operating system (HTTPS through URLSession, the Keychain). It
contains no cryptography of its own and no third-party crypto library. That
is exempt; no documentation or yearly self-classification report is needed.

Last.fm request signing uses an MD5 checksum. A hash used for
authentication is not encryption of data, so the answer does not change,
whether the hash comes from CryptoKit or from the app's own code.

### 12.4 Content rights

App Information → Content Rights: "Does your app contain, show, or access
third-party content?" → **No**.

The app has no catalogue. It plays media from a server the user runs, which
is the user's own content. The same answer is used by other clients for
personal media servers. If you ever bundle or link to content you do not
own, this becomes "Yes".

### 12.5 Pricing and availability

Pricing: **Free** (USD 0.00). Availability: all countries, or your choice.
Leave "Make this app available on Apple Vision Pro / Mac (Designed for
iPad)" as you prefer; untick both if you have not tested there.

### 12.6 Digital Services Act: trader status (EU)

Business → **Digital Services Act** (App Store Connect asks before the app
can be offered in the EU). You declare whether you are a **trader**.

- **Non-trader:** you distribute the app outside any trade, business or
  profession. A free, open-source hobby app with no ads, no purchases and no
  donations collected through it normally fits. Nothing more is shown.
- **Trader:** you act commercially (paid apps, in-app purchases, ads, or the
  app promotes your business). Apple then verifies and **publishes** your
  address, phone number and email on the product page.

Apple cannot decide this for you and neither can this guide. If you later
add paid features or run the project as a business, change the status. As a
German resident, also check whether the public pages need an Impressum
(§ 5 DDG); for a purely private, non-commercial project they usually do not.

### 12.7 Not needed

- IDFA / advertising identifier: not used.
- App Tracking Transparency: not used.
- In-app purchases, subscriptions, Game Center, Sign in with Apple: none.

## Step 13: Submit

1. App → the **1.0.0** version page. Under **Build**, select the build you
   tested in step 8.
2. **App Review Information**: contact name, phone and email are there if
   you set the `REVIEW_*` variables. Leave **Sign-in required** unticked:
   the demo account has an empty password, which the form cannot hold. The
   notes start with the sign-in instructions instead.
3. Read the notes once more. They come from
   `ios/fastlane/metadata/review_information/notes.txt`.
4. Version Release: **Manually release this version**, so you choose the
   moment.
5. **Add for Review** → **Submit to App Review**. Status: *Waiting for
   Review*. First reviews usually finish within one to three days.

Or from the command line, once the listing is complete:
`bundle exec fastlane release submit:true`.

If the app is rejected, answer in the Resolution Center. Reply to the exact
guideline quoted, point to the review notes, and offer a screen recording.
Do not resubmit unchanged without replying.

---

## The demo account

A reviewer cannot test a client for self-hosted servers without a server.
An app they cannot sign in to is rejected under guideline 2.1 before anyone
looks at a feature.

The review notes point to the Jellyfin project's public demo:
`https://demo.jellyfin.org/stable`, user `demo`, empty password. It needs no
upkeep, but you do not control it: it resets hourly, can be offline, and its
music library may change. **Sign in to it with the release build the day you
submit.**

The robust alternative is your own small demo server: Jellyfin in a
container on any always-on host, reachable over HTTPS, with a read-only user
and the synthetic library from `scripts/dev-jellyfin/`. Then put its address
and credentials in `demo_user.txt`, a new `demo_password.txt` and the notes,
and tick "Sign-in required". Keep it running until the review is done, and
again for every update.

## App Review justifications

These are in the review notes already. They are repeated here so you can
answer follow-up questions.

### App Transport Security

Info.plist sets `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = true`
and nothing else. This is the tightest setting that works:

- The only hosts the app contacts are typed in by the user. They are not
  known at build time, so `NSExceptionDomains` cannot list them.
- Self-hosted servers on a home network or VPN commonly speak plain HTTP
  under names such as `jellyfin.fritz.box`, `nas.lan`, `server.home.arpa`
  or `host.tailnet.ts.net`. Public certificate authorities do not issue
  certificates for most of these names.
- `NSAllowsLocalNetworking` covers only IP literals, `.local` names and
  unqualified host names. The names above are fully qualified, so that key
  alone would break them.
- `NSAllowsLocalNetworking` must not be added "to be safe": on iOS 10 and
  later its presence makes the system **ignore** `NSAllowsArbitraryLoads`.
  (The project had both keys before; plain HTTP to a named host silently
  did not work.)

Text for App Review:

> Jellyamp connects only to the media server address that the user enters.
> Self-hosted Jellyfin servers are typically reached on a home network or a
> private VPN, where plain HTTP is common and publicly trusted TLS
> certificates cannot be issued for the host names in use (for example
> http://nas.lan:8096). These host names are chosen by each user and are not
> known at build time, so they cannot be listed as exception domains, and
> NSAllowsLocalNetworking does not cover fully qualified private names.
> HTTPS is used whenever the user's server address is https://. The app has
> no web views, no advertising and no third-party SDKs, and it makes no
> connections to hosts the user did not configure.

### Background audio

`UIBackgroundModes` contains `audio` and nothing else. The app is an audio
player: it continues playing the user's music when the screen is locked or
another app is in front, publishes Now Playing information and handles the
remote commands. It does no other work in the background.

### Local network

`NSLocalNetworkUsageDescription` explains the system prompt that appears
when the user's server is on their own network. There is no
`NSBonjourServices` key because the app does not browse for or advertise
Bonjour services. If server discovery is added later, the service types go
there, and UDP broadcast discovery additionally needs the multicast
entitlement, which Apple grants on request.

## Common rejections for media-server clients

| Guideline | What goes wrong | How this project handles it |
|---|---|---|
| 2.1 App completeness | Reviewer sees only a login screen and cannot get past it | Demo server and step-by-step sign-in at the top of the review notes; step 8 makes you test it |
| 2.1 | Crash or empty screens on iPad, or in landscape | All orientations enabled, no `UIRequiresFullScreen`; step 8 covers iPad and rotation |
| 4.2 Minimum functionality | "It is just a wrapper around a website" | Native player: gapless engine, offline downloads, lock-screen integration, Shortcuts. The notes list what to try |
| 2.5.4 Background modes | `audio` background mode declared without audible audio | Only `audio` is declared and it is the app's purpose; justification in the notes |
| 2.5.1 / ATS | `NSAllowsArbitraryLoads` without a reason | Justification in the notes and above |
| 5.1.1 Privacy | Missing or unreachable privacy policy, vague purpose strings | Policy on GitHub Pages and linked in Settings → About; local-network purpose string says what and why |
| 5.1.2 | Privacy label does not match behaviour | No SDKs, no analytics; label "Data Not Collected" matches the privacy manifest |
| 2.3.1 / 2.3.7 Accurate metadata | Description promises missing features; other brands or platforms in name, subtitle or keywords | Check script bans other products' names in the listing; step 8.7 makes you compare features |
| 5.2.1 Intellectual property | Third-party trademarks or copyrighted artwork in icon or screenshots | Original icon; "Jellyfin" appears only to say what the app connects to; screenshots use the synthetic library |
| 5.2.3 | App downloads media from third-party sources | Downloads come only from the signed-in user's own server; say so if asked |
| 4.1 Copycats | Name or look too close to another app | Original icon and UI. The name follows the long "-amp" tradition for music players; if Apple objects, rename to "Jellyamp for Jellyfin" or similar |
| 3.1.1 | Links to external purchases or donations | None in the app. Do not add a donate button without reading 3.1 first |

Using the name "Jellyfin": the listing says the app is a player *for*
Jellyfin and states that it is not affiliated. That is descriptive use and is
what other Jellyfin clients on the store do. Do not use the Jellyfin logo.

## Cutting later releases

1. Bump `MARKETING_VERSION` in `ios/project.yml` (for example `1.1.0`). The
   build number needs no attention; `fastlane beta` numbers builds itself.
2. Write `ios/fastlane/metadata/{en-US,de-DE}/release_notes.txt` for users.
3. Merge to `main`, then tag: `git tag v1.1.0 && git push origin v1.1.0`.
   The TestFlight workflow uploads the build. The lane refuses a tag that
   does not match `MARKETING_VERSION`.
4. Test the TestFlight build, including the demo sign-in.
5. `bundle exec fastlane release` creates the new version in App Store
   Connect and uploads texts and screenshots. Review it there, then submit:
   `bundle exec fastlane release submit:true`.
6. After approval, release manually in App Store Connect.

When something user-visible changes, revisit: screenshots, the description,
`docs/PRIVACY.md` (new data flows), `PrivacyInfo.xcprivacy` (new
required-reason APIs; the check script flags undeclared ones), and the
review notes.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "Signing for Jellyamp requires a development team" | `Config/Signing.xcconfig` is missing or the team ID is wrong; re-run `xcodegen generate` after fixing it |
| `fastlane beta`: "Cloud signing permission error" or no profiles found | The API key is not Admin (step 4), or the App ID from step 2 does not exist |
| Upload rejected: "Invalid large app icon … alpha channel" (ITMS-90717) | The icon was replaced by hand; run `scripts/generate-app-icon.py` |
| Mail from Apple: ITMS-91053 "Missing API declaration" | New code uses a required-reason API; add it to `PrivacyInfo.xcprivacy` |
| Upload rejected: "bundle version must be higher" | A build with that number exists; run `fastlane beta` again (it asks TestFlight for the latest number) |
| HTTP server by host name fails, IP address works | Someone added `NSAllowsLocalNetworking` back; see App Transport Security above |
| Build stuck in "Processing" for hours | Apple-side; wait, or upload again |
| `xcodegen generate` complains about a config file | `Config/Jellyamp.xcconfig` must exist; only `Signing.xcconfig` is optional |

---

## Appendix A: CarPlay (optional, later)

CarPlay audio apps need an entitlement that Apple grants per team on
request (<https://developer.apple.com/contact/carplay/>, category Audio).
Until it is granted, the entitlement must stay out of the project or
automatic signing fails. The app's CarPlay code sits behind an opt-in
switch; `docs/CARPLAY.md` describes it and how to turn it on.

Once Apple has approved the request:

1. Enable **CarPlay Audio App** on the App ID (step 2 page → edit).
2. In `ios/project.yml`, add `com.apple.developer.carplay-audio: true` under
   `entitlements.properties` (the place is marked) and follow
   `docs/CARPLAY.md` for the scene configuration.
3. `xcodegen generate`, archive, and mention CarPlay in the review notes and
   the description.

## Appendix B: Distributing the companion server

`jellyamp-server` (`server/`) is optional and never goes through App Review,
but the store description mentions it, so it should be easy to get.

- Publish the image to the GitHub Container Registry so users can run
  `docker compose up` without building:

  ```sh
  docker buildx build --platform linux/amd64,linux/arm64 \
    -t ghcr.io/djtobi24/jellyamp-server:1.0.0 \
    -t ghcr.io/djtobi24/jellyamp-server:latest --push server
  ```

  Set the package to public afterwards (GitHub → Packages → Package
  settings). A workflow that does this on `v*` tags with
  `docker/build-push-action` and the built-in `GITHUB_TOKEN`
  (`permissions: packages: write`) is the natural next step.
- **Licensing:** the slim image (default build) contains only permissively
  licensed dependencies. The analysis image (`--build-arg WITH_ANALYSIS=1`)
  includes Essentia, which is AGPL-3.0, and uses pretrained models that have
  their own, partly non-commercial licences. If you publish that image, say
  so in the image description, link to the source, and read
  `docs/adr/0004-fastapi-essentia-backend.md` first. The iOS app is not
  affected; it only talks to the server over HTTP.
- Keep the server's API version in step with the app: `docs/SONIC-API.md` is
  the contract, and the app must keep working when the server is absent.
