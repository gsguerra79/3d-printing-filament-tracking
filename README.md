# Filament Inventory

A local filament inventory app for tracking what is loaded in the CFS, open in the dehumidifier, and sealed in stock.

## Start

```bash
python3 app.py
```

Then open:

```text
http://127.0.0.1:8765
```

The app stores data in `filament_inventory.sqlite3` in this folder.

## Tracks

- Material, brand, color, and swatch
- Original and remaining grams
- Status: sealed, open, loaded, retired
- Location: CFS slots, dehumidifier, open storage, sealed stock
- Usage events that subtract grams from a spool
