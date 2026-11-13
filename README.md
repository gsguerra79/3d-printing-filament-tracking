# Creality K2 Filament Tracker and Inventory

Current release: **2.3** (build 23). See [CHANGELOG.md](CHANGELOG.md) for changes.

A native macOS app for tracking filament spools and inventory for a Creality
K2 Plus 3D printer — what's loaded in each CFS (Color Filament System) slot
and the external spool holder, remaining weight per spool, usage history,
and a catalog of Creality Print's bundled filament profiles. It talks to
the printer directly over its Moonraker API, so slot/usage state updates in
real time as you print.

This is a full SwiftUI/Swift 6 rewrite of an earlier Python/Flask
prototype. The Python version is retired; this is now the actively
developed and used app.

## Features

- **Menu bar glance**: printer connection status and what's currently
  loaded, with color-coded remaining-weight bars, from the menu bar at all
  times.
- **Main window**: a left column of at-a-glance stats (total/open/sealed
  counts), inventory categories, filament-type browsing, and settings;
  a persistent top-right panel showing all four CFS slots, the external
  holder, and printer status; and a bottom-right inventory grid with a
  per-spool detail page (edits autosave, no save button).
- **Real-time printer sync**: connects to Moonraker's websocket API,
  subscribes to CFS/filament-rack/print-stats updates, and reconciles
  loaded spools against inventory as slots change — conservatively: it
  never guesses an identity match it isn't confident about, and surfaces a
  mismatch instead of silently resolving one.
- **Usage tracking**: estimates grams consumed during a print from the
  printer's own reporting and deducts it from the correct spool(s),
  including multicolor prints with multiple simultaneously-loaded spools.
- **Creality Print catalog import**: reads the filament profiles bundled
  with the Creality Print app (if installed) to populate a Brand → Type →
  Name picker when adding or editing a spool.
- **Manual tracking correction**: a dedicated screen for resolving usage
  the tracker couldn't safely auto-assign to a spool.
- **Runs like a normal Mac app**: a proper app icon and menu bar icon (both
  drawn to match the in-app spool graphic), and registers itself as a
  login item so it starts automatically — no LaunchAgent plist to install
  by hand.

## Requirements

- macOS matching this project's deployment target (currently macOS 26.5 —
  check **Signing & Capabilities → Deployment Info** in Xcode if you lower
  it for an older Mac; the SwiftUI APIs in use, like `MenuBarExtra` and the
  Observation framework, only need macOS 13+, so the target can likely be
  lowered without code changes if you need to run on an older OS).
- Xcode 16 or later (Swift 6 language mode).
- A Creality K2 Plus (or similar Klipper/Moonraker-based printer exposing
  CFS-style objects) reachable on the local network, for live printer sync.
  The app is still useful as a manual inventory tracker without one.
- Optionally, [Creality Print](https://www.creality.com/pages/download-Creality-print)
  installed locally, to auto-import its bundled filament profile catalog.

## Building and running

1. Open `Creality K2 Filament Tracker and Inventory.xcodeproj` in Xcode.
2. Select your own team under **Signing & Capabilities** (a free "Personal
   Team" works fine for local/personal use — no paid Apple Developer
   Program membership required).
3. Build and run (⌘R).

On first launch, the app creates its own SQLite database in
`~/Library/Application Support/` and seeds the standard CFS + external
holder locations. If it finds a compatible legacy database from the older
Python app at its expected path, it offers to migrate that data in —
otherwise it just starts empty.

Enter your printer's address under the left column's **Settings → Printer
Connection** page to connect. Everything else (adding spools, browsing
inventory, tracking usage) works without a printer connection too.

### Installing it like a normal app (not just running from Xcode)

Running via ⌘R builds into Xcode's temporary DerivedData folder — it won't
show up in Launchpad or launch at login from there. To install it properly:

1. **Product → Archive** in Xcode.
2. In the Organizer window that opens, select the archive → **Distribute
   App → Copy App** (Developer ID / App Store options require a paid
   Developer account and aren't needed here).
3. Export to `/Applications` (or export elsewhere and drag it in).
4. First launch: since this isn't notarized (no paid Developer account),
   macOS will block a plain double-click. Right-click (or Control-click)
   the app → **Open** → confirm **Open** in the dialog. This is a one-time
   step; the app is trusted after that.
5. The app registers itself as a login item automatically on launch (via
   `SMAppService`) — check **System Settings → General → Login Items &
   Extensions** to confirm, or toggle it off there if you don't want that.

## Architecture

- **UI**: SwiftUI throughout, `@Observable` (Observation framework) for
  state rather than Combine's `ObservableObject`. `AppModel.swift` is the
  single `@MainActor` model object the whole UI reads from and drives
  actions through.
- **Layout**: `ContentView` is a plain three-pane `HStack`, not a
  `NavigationSplitView` — `LeftColumnView` (stats/categories/filament
  types/settings) drives what `ContentAreaView`'s `NavigationStack` shows,
  while `PersistentHeaderView` (CFS panel + printer status) stays mounted
  regardless of navigation.
- **Data**: raw `SQLite3` C API (no SPM dependency), schema mirrors the
  original Python app's so an existing database migrates in unchanged.
  `SpoolRepository.swift` holds printer-sync-facing queries;
  `SpoolEditing.swift` holds the user-editing/catalog layer as a separate
  extension.
- **Printer sync**: `MoonrakerClient.swift` is a `URLSessionWebSocketTask`
  JSON-RPC client with auto-reconnect; `PrinterSyncEngine.swift` merges its
  (partial) status pushes field-by-field into a running snapshot and drives
  `UsageTrackingEngine.swift`'s allocation logic on a throttled timer.
- **Icons**: the app icon and menu bar glyph are static assets, generated
  from a Python/Pillow script that ports `SpoolGraphic.swift`'s geometry —
  not rendered live from SwiftUI, since app icons have to be static image
  assets regardless of platform.

## Known limitations

- Not notarized (see install steps above) — expected for personal-use,
  non-distributed builds under a free Apple ID; distributing this more
  broadly would need a paid Apple Developer Program membership and
  notarization.
- Printer identity matching is deliberately conservative: it will report a
  slot as "unmatched" or flag a mismatch rather than guess, so some
  situations need a manual correction via the Tracking Error Corrections
  screen.
- Single-user, local-network only — no cloud sync or multi-device support.

## Status

This is the actively maintained version of the filament tracker. The
original Python/Flask prototype has been retired (its LaunchAgent is
stopped; the code remains on disk for reference only, unmaintained going
forward).
