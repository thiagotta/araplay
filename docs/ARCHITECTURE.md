# Architecture

AraPlay is ~4,000 lines of Swift in four layers. Dependencies point downward
only; nothing below `UI/` knows SwiftUI exists, and nothing outside
`Playback/` knows which engine is running.

```
Sources/
  App/         Composition root. AraPlayApp (scenes, menus), AppDelegate
               (file-open events, Dock menu, Now Playing wiring)
  UI/          RootView, StageView, TransportBar, RecentsSidebar,
               SettingsView, Theme. Binds to PlayerController only.
  Playback/    PlayerController (single source of truth), PlaybackEngine
               protocol, AVFoundationEngine, MPVEngine, EngineSelector,
               MediaMetadataReader
  Library/     RecentItem, RecentsStore — no playback knowledge
  System/      NowPlayingCenter, DefaultAppRegistrar — macOS integration leaves
```

`PlayerController` is the hub: the UI observes it (`@Observable`), engines
report into it (`PlaybackEngineDelegate`), and it owns the recents side
effects (move-to-top, resume positions, cached tags). The two menu→UI channels
that bypass it (sidebar toggle, search focus) go over `NotificationCenter`
because they are view concerns, not player state.

## Two engines, one contract

**AVFoundation is preferred**: hardware decode, the lowest power draw, and the
OS-native path for the formats it supports. **mpv (via MPVKit) is the
catch-all** for everything AVFoundation cannot open — MKV, WebM, Opus, APE,
WavPack, DSD — rendering through `gpu-next` on Vulkan/MoltenVK with
VideoToolbox hardware decode.

`EngineSelector` routes each file:

1. A list of known-unsupported containers goes straight to mpv. This list is
   load-bearing: probing an MKV can *half-succeed* (video plays, audio
   silent), so "let AVFoundation try" is not safe for them.
2. Everything else is probed — the asset must load and report at least one
   decodable track. Any doubt resolves to mpv.
3. If the probe was wrong in the optimistic direction, the engine reports
   `.unsupported`, and `PlayerController` re-opens the same file on mpv at the
   position already reached. The user sees a brief pause, not an error.

A stub `MPVEngine` compiles when `Libmpv` is absent, so the project builds
without the dependency and reports every mpv-routed file as unsupported.

## mpv integration notes

Hard-won rules, each learned from a real failure. Violating any of them
produces symptoms that do not point back at the cause.

**Never call `mpv_get_property` from mpv's event delivery.** It is synchronous
and takes the core's dispatch lock; called from a property-change handler, the
core is waiting for the handler while the handler waits for the core. The app
does not crash — it beachballs forever with a frozen clock, which reads as a
rendering bug. Everything the app needs (tags, dimensions, the album-art flag)
is registered with `mpv_observe_property` and arrives through the same event
pump. Add future values to `observedProperties`; never fetch them.

**All built-in Lua scripts are disabled** (`load-scripts=no` and the
per-script switches), plus `config=no` so a user's `~/.config/mpv` cannot
re-enable them. mpv's OSC, console and stats are Lua, and LuaJIT compiles
machine code at runtime — under the Hardened Runtime that is terminated as
`SIGKILL (Code Signature Invalid)` the moment a script requires a native
module. Debug builds hide the crash (`get-task-allow` relaxes the rules),
which is exactly why it only surfaced in Release. AraPlay draws its own
transport and OSD, so nothing of value is lost — and with Lua fully off, the
app needs **no JIT entitlements at all** (verified: MKV/Opus/MP3 all play in a
Release build signed with none).

**mpv cannot learn its size once handed a `CAMetalLayer`.** Embedding uses
`wid` pointing at the layer (`gpu-context=moltenvk`); the documented
`NSView` form hangs during Vulkan surface creation in this build. The
consequence: mpv's own viewport query returns 0×0 after any resize, so the
picture stays at the size the video output was created with while the layer
resizes correctly underneath it. Every in-place fix failed (view attach,
context auto-probe, layer-as-view's-own-layer, runtime `vo` reinit — the last
kills output entirely). What works: a fresh engine always reads the size
correctly, so `PlayerController` rebuilds the mpv engine at the current
position ~350ms after a resize settles, debounced so drags rebuild once.
Guards prevent the rebuild's own layout churn from re-triggering it. The
clean fix would be mpv's render API (`mpv_render_context`), where the app
passes the framebuffer size every frame; that is the known next step if the
interruption ever matters.

**`media-title` is not a title.** mpv falls back to the file name, extension
and all, when a file has no title tag. The engine rejects that value; the UI
has its own file-name fallback that at least strips the extension.

Also: embedded cover art surfaces as a video track. The observed
`current-tracks/video/albumart` flag keeps the width/height handlers from
mistaking an album for a movie.

## Metadata

Two independent sources fill one `MediaInfo`, in whatever order they land:

- `MediaMetadataReader` (AVFoundation) reads tags for *every* file regardless
  of engine — AVFoundation parses tags for far more formats than it can
  decode, and it is the only artwork source. It normalizes the awkward
  spellings: `(17)Rock` genres, `3/14` tracks, `2001-07-23` dates.
- The active engine reports what it is decoding (video or not, natural size),
  and mpv supplies FFmpeg-normalized text tags for containers AVFoundation
  cannot open at all.

`MediaInfo.applying` makes the merge order-tolerant: a source adds what it
knows and can never blank out what the other found. Neither source invents a
title for untagged files — display fallbacks live in the UI layer, so a
fabricated title never gets cached into recents as if it were a tag.

## Recents

A 200-entry LRU (`RecentsStore`), JSON-persisted to Application Support with
debounced writes and an unconditional flush at quit. Entries locate their file
by **bookmark**, with the path as display cache and fallback: a moved or
renamed file heals its entry, and only an unresolvable one is flagged missing
(a transient fact about the disk, deliberately not persisted). Playing a file
moves it to the top — except previous/next stepping, which walks the list
*without* reordering it, because moving each visited file to the top would
make "next" undo "previous" forever.

Resume positions are cleared when a file plays to within ten seconds of its
end, so finished files start over instead of dropping into the credits.

## Window chrome

The window hides the system title bar (`.hiddenTitleBar`), which silently
forfeits standard behavior that had to be restored deliberately:

- With a transparent title bar, `NSTitlebarContainerView` hit-tests to nil
  everywhere except the traffic lights — clicks fall through to SwiftUI and
  the window never sees them. `TitleBarInteractionArea` (an `NSView` behind
  the title label) restores dragging and the double-click zoom/minimize
  action, honoring the user's System Settings choice.
- SwiftUI already insets content below the title bar via the safe area.
  Adding the bar's height again produces a dead band — the top inset is just
  the standard margin, and the title label uses `.ignoresSafeArea` to sit on
  the traffic lights' line.
- The engine's render view is hit-test transparent (`PassthroughView`);
  otherwise AppKit consumes clicks over the picture and no SwiftUI gesture on
  the stage ever fires. Similarly, the transport bar's hover region is
  attached *before* the full-height positioning frame — modifier order
  determines the region, and attached after it, "hovering the controls" would
  cover the whole stage and block the auto-hide.

## Testing strategy

Unit tests (`Tests/`, Swift Testing, hosted in the app) cover the pure logic
where a regression would be silent: tag parsing/normalization, the
`MediaInfo` merge contract, `RecentsStore` (LRU ordering, identity across
replays, capacity trim, search, resume semantics, missing-file tracking,
persistence round-trip, corrupt-store recovery), `RecentItem` progress
bounds, engine routing, and time formatting.

Deliberately not unit-tested:

- **The engines.** They are adapters over AVFoundation and libmpv; their
  failure modes (deadlocks, codec behavior, rendering) do not reproduce under
  a unit harness. They are verified by playing real files across both engines
  and sampling the process for responsiveness — liveness checks alone cannot
  distinguish a healthy app from a deadlocked one.
- **SwiftUI views.** Thin bindings over `PlayerController`; the logic worth
  testing lives in the controller and below.

## Release builds

- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` on Release strips
  `get-task-allow`, which ad-hoc signing otherwise injects and notarization
  rejects.
- No entitlements: hardened runtime with nothing relaxed.
- Builds are ad-hoc signed — fine locally, Gatekeeper-blocked on other Macs.
  Distribution needs a Developer ID certificate and notarization.
- MPVKit's default (LGPL) product is used, not `MPVKit-GPL`.
