# Filament Inventory

A local web app for tracking 3D printer filament across a Creality K2 Plus with CFS, open storage/dehumidifier, and sealed stock.

The app runs on your Mac, stores everything in a local SQLite database, and can sync CFS slots plus track filament usage from the printer through the Fluidd/Moonraker-style printer dashboard.

## What You Need To Change

If you are setting this up on another Mac, update these items:

- Printer address: use your printer dashboard URL, for example `http://192.168.5.237:4408`.
- Local folder path: update any `/Users/gabriel/Documents/3D Printing Filament Tracking` paths in the macOS LaunchAgent if your folder is somewhere else.
- Python path: the included LaunchAgent uses `/opt/homebrew/bin/python3.12`; change it if your Python 3.12 is installed elsewhere.
- App name/LaunchAgent label: optional, but you can rename `com.gsguerra.filament-tracker` if you want your own service name.
- Database: do not use someone else's `filament_inventory.sqlite3` unless you want their inventory. Delete it before first launch to start fresh.

## Features

- Track material, brand, color, original weight, and remaining weight.
- Track status: loaded, open, sealed, retired.
- Track locations: CFS Slot 1-4, dehumidifier, open storage, sealed stock.
- Sync loaded CFS slots from the K2 Plus printer dashboard.
- Automatically deduct filament usage from loaded CFS spools while prints run.
- Keep individual spools unique when moving between sealed stock, open storage, dehumidifier, and CFS.
- Search/filter inventory and manage spools from a local browser UI.
- Delete accidentally created spools.

## Requirements

- macOS
- Python 3.12
- K2 Plus and CFS reachable on your local network
- Fluidd/Moonraker-style printer dashboard reachable from the Mac

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

If port `8765` is busy, the app will try the next available port up to `8775`.

## First Setup

1. Start the app.
2. Open the local app URL in your browser.
3. In `K2 Plus CFS Sync`, enter your printer dashboard address.
4. Click `Test` to confirm the printer is reachable.
5. Click `Sync CFS` to pull the currently loaded CFS slots into the app.
6. Add your sealed and open inventory manually.
7. Correct the remaining weight of each CFS spool once, then let automatic tracking deduct future print usage.

## Printer Address

Use the address for your printer dashboard, not the local app address.

Example:

```text
http://192.168.5.237:4408
```

Your friend will almost certainly need to replace this with their printer's IP address.

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
/Users/gabriel/Documents/3D Printing Filament Tracking/logs/filament-tracker.out.log
/Users/gabriel/Documents/3D Printing Filament Tracking/logs/filament-tracker.err.log
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

This file contains your actual spool inventory and usage history. It is not a generic starter file.

To start with a blank inventory:

1. Stop the app.
2. Move or delete `filament_inventory.sqlite3`.
3. Start the app again.

The app will recreate the database with the standard locations.

## Important Workflow Notes

- If you load a sealed spool into the CFS, first mark or move that existing spool in the app instead of creating a new one.
- If a CFS sync sees an already loaded spool, it should preserve that unique spool rather than creating a duplicate.
- When replacing CFS filament, update the inventory location/status first, then sync the CFS.
- After manually correcting the remaining grams for a loaded spool, automatic tracking uses that number as the baseline for future deductions.

## Files

- `app.py`: local web server, SQLite database, printer sync, usage tracking.
- `static/index.html`: app layout.
- `static/app.js`: browser UI behavior.
- `static/styles.css`: app styling.
- `mac/com.gsguerra.filament-tracker.plist`: optional macOS auto-start service.
- `Start Filament Tracker.command`: double-click manual starter for macOS.
- `filament_inventory.sqlite3`: local app data.

## Backup

To back up your inventory, copy:

```text
filament_inventory.sqlite3
```

That one file contains the spool database and usage history.
