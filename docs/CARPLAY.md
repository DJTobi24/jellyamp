# CarPlay

Jellyamp contains a complete CarPlay audio app. It is **compiled into every
build but switched off by default**, because CarPlay needs an entitlement that
Apple grants per developer team on request. Until Apple has approved it, a
build that declares the entitlement cannot be signed for a device or uploaded.

This document covers what the CarPlay app does, how the switch works, how to
request the entitlement, and how to test.

## What is there

| Area | Content |
|---|---|
| **Home** tab | Shuffle Liked Songs, Mixes for You (only when the sonic provider reports `mixes`), Recently Added, Recently Played |
| **Library** tab | Artists → artist (Shuffle All, Start Radio, albums) → album → songs; Albums; Playlists; Liked Songs; Genres (with Start Radio) |
| **Downloads** tab | Offline music grouped by album, Shuffle All. Built from the local download index, so it works without a connection |
| **Now Playing** | System template: shuffle, repeat and like buttons, Up Next list (tap an entry to jump to it) |
| Signed out | A single "Not Signed In" page asking the user to sign in on the iPhone |

Behaviour worth knowing:

- **Cold launch.** CarPlay can start the app while the phone is locked and
  the phone UI was never opened. Then only the CarPlay scene exists — no
  window, no SwiftUI views. The scene uses `DependencyContainer.shared` and
  `ensureBootstrapped()` to restore the session itself.
- **Limits.** Head units cap the number of rows and sections
  (`CPListTemplate.maximumItemCount` / `maximumSectionCount`). Lists are cut
  to those limits; a truncated album or playlist still *plays* completely,
  only the visible rows are limited. Very large libraries therefore show the
  first part of Artists/Albums alphabetically — voice ("Play … in Jellyamp")
  reaches everything.
- **Depth.** Audio apps may stack at most 5 templates. The deepest path
  (Library → Artists → artist → album → Now Playing) uses exactly 5; opening
  Up Next from there rebuilds the stack as root → Now Playing → Up Next.
- **Loading and errors.** A tapped row shows CarPlay's spinner until its data
  arrived; failures are reported with an alert.
- **Artwork** is requested at the exact pixel size of
  `CPListItem.maximumImageSize`, cropped square off the main thread and
  cached.

Code map:

| File | Role |
|---|---|
| `ios/Packages/JellyampCore/Sources/JellyampCore/CarPlay/` | Pure, unit-tested list building: sections, truncation, titles, depth rule |
| `ios/Jellyamp/Services/CarPlay/CarPlaySceneDelegate.swift` | Scene entry point, localized strings |
| `ios/Jellyamp/Services/CarPlay/CarPlayCoordinator.swift` | Templates, data loading, Now Playing, state sync |
| `ios/Jellyamp/Services/CarPlay/CarPlayArtworkLoader.swift` | Artwork download, sizing, cache |
| `ios/Jellyamp/Services/Intents/MusicCommands.swift` | Playback actions shared with Siri/Shortcuts |
| `ios/project.carplay.yml` | The switch (scene manifest + entitlement) |

## The switch

```sh
cd ios
xcodegen generate                        # default: CarPlay off
CARPLAY_ENABLED=YES xcodegen generate    # CarPlay on
```

`project.yml` includes `project.carplay.yml` with
`enable: ${CARPLAY_ENABLED}`. XcodeGen expands environment variables in the
spec; when the variable is not set, the placeholder is left as text and is
read as *false*, so nothing is included. `YES`, `true` and `1` turn it on.

Turning it on adds exactly two things:

1. **Info.plist** — a scene manifest with the CarPlay scene:

   ```
   UIApplicationSceneManifest
     UIApplicationSupportsMultipleScenes = true
     UISceneConfigurations
       CPTemplateApplicationSceneSessionRoleApplication
         - UISceneConfigurationName  = CarPlay
           UISceneClassName          = CPTemplateApplicationScene
           UISceneDelegateClassName  = $(PRODUCT_MODULE_NAME).CarPlaySceneDelegate
   ```

2. **Entitlements** — `com.apple.developer.carplay-audio = true`.

Because the Xcode project, `Info.plist` and the `.entitlements` file are all
generated (and git-ignored), switching back is just running
`xcodegen generate` again without the variable.

To check which variant a generated project is:

```sh
grep -c CPTemplateApplicationSceneSessionRoleApplication ios/Jellyamp/Info.plist
grep -c carplay-audio ios/Jellyamp/Jellyamp.entitlements
```

### Why a manifest in a SwiftUI app needs care

Jellyamp uses the SwiftUI app lifecycle (`@main struct JellyampApp: App` with a
`WindowGroup`) and has no scene manifest by default — SwiftUI supplies the
phone's window scene itself. Adding a manifest for CarPlay has three
consequences, all handled:

- **Declare only the CarPlay role.** The manifest must *not* contain a
  `UIWindowSceneSessionRoleApplication` entry. With one (especially with a
  delegate class or storyboard name) UIKit would use that configuration for
  the phone window and the SwiftUI `WindowGroup` would no longer drive it —
  the classic result is a black screen. For the same reason `AppDelegate`
  must not implement `application(_:configurationForConnecting:options:)`.
- **`UIApplicationSupportsMultipleScenes` must be `true`**, otherwise the
  CarPlay scene cannot exist next to the window scene. On iPad this key also
  permits several windows of the app. That is safe here: every window uses the
  same `DependencyContainer.shared`, and bootstrap runs once no matter how
  many scenes ask for it.
- **The window is no longer guaranteed to exist.** When the car launches the
  app, `JellyampApp.init` and `AppDelegate` run (so the audio session is
  configured), but the `WindowGroup` content is never built and its
  `.task { … }` never fires. Anything that must happen at launch has to be
  reachable without a view — which is why session restore lives in
  `DependencyContainer.ensureBootstrapped()` and is called from the window,
  the CarPlay scene and every Siri intent alike.

## Requesting the entitlement

1. Sign in at <https://developer.apple.com/contact/carplay/> as the **Account
   Holder** of the team (other roles cannot submit the form).
2. Fill in the form:
   - **App name:** Jellyamp. **Bundle ID:** `dev.djtobi.jellyamp`.
     App Store / TestFlight link if one exists.
   - **Entitlement / category:** *CarPlay Audio App*.
   - **Description** — suggested text:

     > Jellyamp is a music player for self-hosted Jellyfin media servers. It
     > streams the user's own music library and plays music downloaded for
     > offline listening. In CarPlay it offers browsing of the user's
     > library (artists, albums, playlists, genres, liked songs), recently
     > played and recently added music, offline downloads, and standard
     > playback controls with an Up Next queue, using the CarPlay audio
     > templates (tab bar, list, now playing). The app plays audio only; it
     > shows no video, lyrics or other text content while driving and
     > requires no account creation or sign-in inside CarPlay.

   - Confirm that the app's primary purpose is audio playback and accept the
     CarPlay entitlement terms.
3. Wait for Apple's e-mail. Approval is per team; it typically takes from a
   few days to a few weeks, and Apple may ask follow-up questions.
4. After approval, in *Certificates, Identifiers & Profiles → Identifiers →*
   `dev.djtobi.jellyamp`, enable **CarPlay Audio App** (it appears under the
   additional / requested capabilities once granted) and save.
5. With automatic signing Xcode then fetches a new provisioning profile on
   the next build. With manual signing (CI, fastlane match) regenerate the
   development, ad-hoc and App Store profiles so that they contain
   `com.apple.developer.carplay-audio`.
6. Generate with `CARPLAY_ENABLED=YES` from then on — in the release workflow
   too, once the release profile contains the entitlement.

Until step 5 is done, a `CARPLAY_ENABLED=YES` build fails to sign for devices
with "Provisioning profile doesn't include the
com.apple.developer.carplay-audio entitlement". Simulator builds are not
affected.

App Review checks CarPlay apps against the CarPlay guidelines: use only the
audio templates (done), no playback UI that requires reading while driving,
and everything must work without touching the phone.

## Testing

### iOS Simulator (no Apple approval needed)

The Simulator does not verify provisioning profiles, so the enabled variant
runs there right away.

```sh
cd ios
CARPLAY_ENABLED=YES xcodegen generate
open Jellyamp.xcodeproj        # run the Jellyamp scheme on an iPhone simulator
```

In the Simulator choose **I/O → External Displays → CarPlay**. A second
window shows the CarPlay home screen with the Jellyamp icon.

If the CarPlay window does not show the app, the Simulator may need the extra
templates switch once:

```sh
defaults write com.apple.iphonesimulator CarPlayExtraOptions -bool YES
```

Restart the Simulator afterwards; the CarPlay window then also offers
different screen sizes and limits.

### Real head unit behaviour without a car

Install *Additional Tools for Xcode* (developer.apple.com → Downloads) and
start **Hardware/CarPlay Simulator.app**. Connect an iPhone running a
device build (needs the approved entitlement) by cable; the Mac then acts as
a head unit, including configurable display sizes and list limits.

### What to check

- [ ] Cold start: force-quit Jellyamp on the phone, lock it, open Jellyamp in
      CarPlay → tabs appear, Home fills in, playback starts.
- [ ] Signed out: the single "Not Signed In" page; signing in on the phone
      replaces it with the tabs without reconnecting.
- [ ] Library → Artists → artist → album → song: Now Playing opens, the row
      shows the playing indicator, artwork appears.
- [ ] Up Next from that depth: stack becomes Now Playing → Up Next, no crash.
- [ ] Shuffle / repeat / like buttons reflect and change the state; the phone
      UI follows.
- [ ] Airplane mode: Downloads tab lists and plays; a Library row shows the
      "Couldn't reach your Jellyfin server" alert.
- [ ] Sonic server configured: "Mixes for You" appears on Home; without it
      the section is absent.
- [ ] Siri in the car: "Play *⟨playlist⟩* in Jellyamp", "Next song in
      Jellyamp".
- [ ] Default build (`xcodegen generate` without the variable): app runs as
      before, no CarPlay icon, signs with the normal profile.

### CI

The iOS workflow builds the default variant. The CarPlay sources are part of
that build, so they are compile-checked on every run. To also verify the
manifest/entitlement merge, add a second generate + build step with
`CARPLAY_ENABLED=YES` (it builds with `CODE_SIGNING_ALLOWED=NO`, so it needs
no profile).
