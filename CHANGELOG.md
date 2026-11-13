## Version 3.0

- Browse cumulative filament usage per project, broken down by material and color.
- Match print jobs against saved Creality Print projects. Unique matches group automatically, and ambiguous matches can be reviewed as suggestions.
- Rename projects, move selected jobs using the full project catalog, or merge into another visible sidebar project using search.
- Keep Inventory and Settings visible at the bottom of the sidebar while Projects scrolls independently.
- Record material and color when new print usage is logged so later spool edits preserve historical totals.

## Version 2.3

Version 2.3 carries forward the same bulk Add Spools and compact Edit workflows shipped in 2.2. This release updates the version to 2.3 (build 23).

## Version 2.2

- Add multiple identical sealed spools in one operation, with a separate inventory record for each spool.
- Add and Edit open compact dialogs. Cancel discards the draft, and OK saves edits to the selected spool.
- Use Edit from the spool card menu. Clicking the card body keeps the inventory grid open.
- Delete Spool is available in the Edit dialog and requires confirmation.

# Version 2.1 — October 28, 2026

- Enter custom spool color names and choose an independent icon color with the native color picker.
- Pick purchase and opening dates from calendars.
- Remove the Log Usage button from the spool detail header.
- Remove Unassigned from the location menu; selecting Sealed selects Sealed Stock.
- Sort inventory by Brand or Color, alongside Type, Status, Purchase Date, and Opening Date.
- Hide retired spools on All Spools with a checkbox whose preference survives relaunch.
- Preserve the existing local dashboard, Fluidd shortcut, menu bar behavior, and printer tracking changes.

The native macOS app remains installed as `/Applications/Filament Tracker.app`, uses the existing Application Support database, and retains its login-item registration. Closing the window leaves the menu bar app running; Quit exits it.
