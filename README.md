# Filament Inventory V2

A local dark-mode web app for tracking filament on a Creality K2 Plus with CFS, external spool holder, dehumidifier/open storage, and sealed stock.

V2 is built around the way the K2 Plus and Creality Print understand filament: brand, type, profile/name, and color come from the Creality Print filament profile catalog instead of a community spool catalog or barcode database.

## What V2 Does

- Tracks each physical spool as a unique inventory item.
- Uses Creality Print filament profiles for controlled Brand, Type, Name, and Color choices.
- Syncs CFS Slot 1-4 from the printer through the Fluidd/Moonraker-style dashboard.
- Syncs the External Spool Holder from the printer too.
- Automatically marks a spool as loaded when it appears in a printer slot.
- Automatically moves a spool back to open/dehumidifier storage when it leaves a printer slot.
- Deducts filament usage from the loaded spool being used by the printer.
- Supports multicolor prints by using the printer-reported active CFS slot.
- Provides a `Fluidd` button that opens the printer dashboard from the current Printer IP field.

## What This Does Not Use

- No barcode workflow.
- No community filament database.
- No manually loaded CSV/JSON catalog.

The source of truth for filament profiles is Creality Print's local profile data on the Mac running the app.

## Requirements

- macOS
- Python 3.12
- Creality Print installed locally
- Creality K2 Plus with CFS
- Printer dashboard reachable on your local network, usually like:

```text
http://192.168.5.232:4408
```

No external Python packages are required; the app uses the Python standard library.

## Run Manually

From the project folder:

```bash
python3.12 app.py
```

Then open:

```text
http://127.0.0.1:8765
```

If port `8765` is busy, the app tries the next available port up to `8775`.

## First Setup For Another K2 Plus Owner

If you share this repo with a friend, they should update these items:

- `Printer IP`: enter their own printer dashboard address in the app header.
- `Creality Print`: install Creality Print so the app can read the local filament profile catalog.
- `LaunchAgent paths`: update any `/Users/gabriel/Documents/3D Printing Filament Tracking` paths if their folder is elsewhere.
- `Python path`: the included LaunchAgent uses `/opt/homebrew/bin/python3.12`; change it if their Python 3.12 is installed elsewhere.
- `Database`: delete `filament_inventory.sqlite3` before first launch if they want a blank inventory instead of this machine's current spool data.

## Printer IP And Fluidd

The Printer IP field is the shared source for:

- CFS sync
- External holder sync
- usage tracking
- the `Fluidd` dashboard button

You can enter either:

```text
192.168.5.232
```

or:

```text
http://192.168.5.232:4408
```

The Fluidd button opens the dashboard at:

```text
http://<printer-ip>:4408/#/
```

If Wi-Fi power-cycles and the printer IP changes, update the Printer IP field, then run a printer action such as `Sync CFS` or `Check Usage` once. The app then uses that new address for automatic tracking.

## Daily Workflow

1. Add each physical spool once.
2. Choose Brand, Type, Name, and Color from the Creality profile-based dropdowns.
3. Correct the remaining grams when needed.
4. Let the app sync CFS/external holder changes from the printer.
5. Let automatic usage tracking deduct grams from the loaded spool.

When a printer slot changes, the app tries to match an existing inventory spool by exact Creality profile plus color. If it cannot safely prove the match, it creates a new printer-synced spool rather than corrupting an existing one.

## Auto Start On macOS

The included LaunchAgent is:

```text
mac/com.gsguerra.filament-tracker.plist
```

Before installing it, edit these paths inside the plist:

```text
/opt/homebrew/bin/python3.12
/Users/gabriel/Documents/3D Printing Filament Tracking/app.py
/Users/gabriel/Documents/3D Printing Filament Tracking
/Users/gabriel/Library/Logs/FilamentTracker/filament-tracker.out.log
/Users/gabriel/Library/Logs/FilamentTracker/filament-tracker.err.log
```

Then copy it into your LaunchAgents folder:

```bash
cp mac/com.gsguerra.filament-tracker.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gsguerra.filament-tracker.plist
launchctl kickstart -k gui/$(id -u)/com.gsguerra.filament-tracker
```

To check status:

```bash
launchctl print gui/$(id -u)/com.gsguerra.filament-tracker
```

To stop/remove it:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.gsguerra.filament-tracker.plist
```

## Data Storage

Inventory data is stored locally in:

```text
filament_inventory.sqlite3
```

This file contains actual spool inventory and usage history. It is not a generic starter file.

To start with a blank inventory:

1. Stop the app.
2. Move or delete `filament_inventory.sqlite3`.
3. Start the app again.

The app recreates the database with standard locations.

## Files

- `app.py`: local web server, SQLite database, Creality profile import, printer sync, usage tracking.
- `static/index.html`: app layout.
- `static/app.js`: browser UI behavior.
- `static/styles.css`: dark-mode styling.
- `mac/com.gsguerra.filament-tracker.plist`: optional macOS auto-start service.
- `Start Filament Tracker.command`: double-click manual starter for macOS.
- `filament_inventory.sqlite3`: local app data.

## Backup

To back up your inventory, copy:

```text
filament_inventory.sqlite3
```

That one file contains the spool database and usage history.
