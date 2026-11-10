# Design

## Look & feel

Plexamp's signature: a dark, artwork-first UI. Huge album art, a blurred
copy of the artwork as the screen background, white controls, a floating
mini player above the tab bar.

## Liquid Glass (iOS 26)

The app is built with the iOS 26 SDK and adopts the Liquid Glass design
language, while still deploying back to iOS 16:

- **System chrome is free.** Tab bar, navigation bars, sheets and form
  controls render as Liquid Glass automatically on iOS 26 devices simply
  because the app is compiled against the iOS 26 SDK. Older OS versions keep
  the classic look. No code involved.
- **Custom surfaces** use the helpers in
  `ios/Jellyamp/DesignSystem/GlassStyle.swift`; every iOS 26 API call is
  gated behind `#available(iOS 26, *)` with an `.ultraThinMaterial` fallback:
  - `glassPanel(cornerRadius:)` → `glassEffect(.regular.interactive(), in: .rect(...))` — mini player, onboarding panels
  - `glassCapsule()` → `glassEffect(.regular, in: .capsule)` — transport-control cluster on Now Playing
  - `glassButtonStyle()` → `.buttonStyle(.glass)`
  - `tabBarMinimizesOnScroll()` → `.tabBarMinimizeBehavior(.onScrollDown)` — tab bar shrinks while browsing
- Glass works best floating above rich content — which is exactly the
  blurred-artwork background we already use. Avoid stacking glass on glass
  (Apple HIG); content layers stay opaque.

CI builds on the `macos-26` runner so these APIs compile (`ios.yml`).

## Layout and navigation

- `AdaptiveShellView` picks the layout from the horizontal size class: a tab
  bar (Home, Library, Search, Downloads, Settings) on compact width, a
  sidebar on regular width. Both share `AppNavigator`, so selection and
  navigation paths survive rotation and multitasking size changes.
- The mini player is docked above the tab bar or at the bottom of the detail
  column; Now Playing is a full-screen cover with its own wide layout.
- The app is dark only (`preferredColorScheme(.dark)`).

## Colour from artwork

`DominantColor` (Core) extracts a vivid dominant colour from the cover;
`ArtworkPalette` caches it per track. It tints the visualizer and Now
Playing. Tiles without artwork (genres) get a stable hue from `StableColor`.

## Motion and accessibility

- Reduce Motion disables the mini-player drag animation, lyric scroll
  animation and the visualizer; Low Power Mode also stops the visualizer.
- Every icon-only button carries an accessibility label; track rows expose
  their context-menu actions as accessibility actions.

## Not built

- `GlassEffectContainer` + `glassEffectID` for morphing the mini player into
  Now Playing.
- Glass tinted from the artwork colour (`glassEffect(.regular.tint(...))`).
- `glassButtonStyle()` exists in `GlassStyle.swift` but no view uses it yet.
- A light appearance.
