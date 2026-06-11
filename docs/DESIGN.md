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
  - `glassPanel(cornerRadius:)` → `glassEffect(.regular.interactive(), in: .rect(...))` — mini player
  - `glassCapsule()` → `glassEffect(.regular, in: .capsule)` — transport-control cluster on Now Playing
  - `glassButtonStyle()` → `.buttonStyle(.glass)`
  - `tabBarMinimizesOnScroll()` → `.tabBarMinimizeBehavior(.onScrollDown)` — tab bar shrinks while browsing
- Glass works best floating above rich content — which is exactly the
  blurred-artwork background we already use. Avoid stacking glass on glass
  (Apple HIG); content layers stay opaque.

CI builds on the `macos-26` runner so these APIs compile (`ios.yml`).

## Future (Phase 4)

- `GlassEffectContainer` + `glassEffectID` for morphing the mini player into
  the full Now Playing screen.
- Art-reactive tinting: `glassEffect(.regular.tint(...))` from the dominant
  artwork color, shared with the visualizer.
