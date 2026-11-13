//
//  PersistentHeaderView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The top-right panel — persistent across every left-column selection: the
//  same rich CFS + External Holder card grid the original web app opened
//  with, now at full card size with the same Load/Unload/Retire/Edit menu
//  as the inventory grid (printer status lives as its own succinct card at
//  the top of the left column instead of duplicating it here). Edit opens the shared editor; Load owns its own popover here since it needs a location picker.
//

import SwiftUI

struct PersistentHeaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var loadTarget: Spool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar

            CFSPanelView(
                onEdit: { spool in model.editingSpool = spool },
                onLoad: { spool in loadTarget = spool },
                onUnload: { spool in model.unloadSpool(spool) },
                onRetire: { spool in model.retireSpool(spool) }
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .popover(item: $loadTarget) { spool in
            LoadSpoolPopoverView(spool: spool) { locationId in
                model.loadSpool(spool, intoLocationId: locationId)
            }
        }
    }

    /// Topmost row of the main window: a quick-launch button to the
    /// printer's Fluidd web UI, using the same host already configured for
    /// the Moonraker connection. Hidden until a printer address is actually
    /// set, since there's nowhere to send it otherwise.
    @ViewBuilder
    private var topBar: some View {
        if let fluiddURL = model.fluiddURL {
            HStack {
                Spacer()
                Button("FLUIDD") {
                    openURL(fluiddURL)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
    }
}
