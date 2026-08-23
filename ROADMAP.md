# Ideas for v3

Captured ideas for a future round of work — not scheduled, not designed in
detail yet, just recorded so they don't get lost.

## Quick-launch Fluidd / Moonraker from the app

Add a button (likely near the printer connection settings, where the
printer's IP is already configured) that opens the printer's web UI
directly in the default browser — Fluidd and/or Moonraker's own
address/port, using the same IP already entered for websocket sync rather
than asking for it twice. Saves a trip to a bookmark or typing the IP by
hand whenever you want the fuller Fluidd interface instead of just this
app's slot/status view.

## Track other printer parts: usage and stock

Extend inventory tracking beyond filament spools to cover the printer's own
consumable/wear parts:

- **Nozzles**: size, grams of filament pushed through it, hours of use,
  stock on hand.
- **Hot ends**: hours of use, stock on hand.
- **Print plate**: hours of use, stock on hand, plate type (e.g. smooth
  PEI, textured, glass).
- **Extruder and other parts**: to be scoped further — likely similar
  hours-of-use + stock shape as the above.

This is a meaningfully different data model from spools (parts don't get
"loaded/unloaded" the same way, and usage accrues by print time and/or
grams-through rather than grams-remaining), so it probably wants its own
schema rather than being bolted onto the existing `spools` table — worth
designing fresh rather than reusing spool-tracking code that doesn't quite
fit.

## Support for more than one printer

Currently the app assumes a single printer (one Moonraker connection, one
set of CFS slots + external holder). Consider what multi-printer support
would need: per-printer connection settings, per-printer location/slot
sets, and a way to tell at a glance which printer a given spool or part is
associated with.

## Resin printer support

Consider adding a resin-based printer as a second printer type, with its
own consumables (resin bottles/volume instead of filament spools/weight,
FEP film, resin vats, IPA/cleaning supplies) — a genuinely different
inventory shape from FDM filament tracking, not just a variant of it.
