//
//  PersistentHeaderView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The top-right panel — persistent across every left-column selection: the
//  same rich CFS + External Holder card grid the original web app opened
//  with, now at full card size with the same Load/Unload/Retire/Edit menu
//  as the inventory grid (printer status lives as its own succinct card at
//  the top of the left column instead of duplicating it here). Edit pushes
//  that spool's detail page onto whichever category is currently showing
//  below; Load owns its own popover here since it needs a location picker.
//

import SwiftUI

struct PersistentHeaderView: View {
    @Environment(AppModel.self) private var model

    @State private var loadTarget: Spool?

    var body: some View {
        CFSPanelView(
            onEdit: { spool in
                if !model.detailPath.contains(spool) {
                    model.detailPath.append(spool)
                }
            },
            onLoad: { spool in loadTarget = spool },
            onUnload: { spool in model.unloadSpool(spool) },
            onRetire: { spool in model.retireSpool(spool) }
        )
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .popover(item: $loadTarget) { spool in
            LoadSpoolPopoverView(spool: spool) { locationId in
                model.loadSpool(spool, intoLocationId: locationId)
            }
        }
    }
}
