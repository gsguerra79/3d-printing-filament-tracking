//
//  CFSPanelView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The CFS tray grid + external spool holder — mirrors renderCfs() /
//  renderExternalHolder() in the old web app. Each of the app's `.cfs`-kind
//  locations (4 CFS slots + the external holder — see DefaultLocations)
//  gets one card showing whatever spool is currently loaded there, or an
//  "Empty" placeholder.
//

import SwiftUI

struct CFSPanelView: View {
    @Environment(AppModel.self) private var model

    var onEdit: (Spool) -> Void
    var onLogUsage: (Spool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CFS & External Holder")
                .font(.title3.weight(.semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(model.cfsLocations) { location in
                    slotCard(for: location)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func slotCard(for location: Location) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(location.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let spool = model.spoolLoaded(atLocationId: location.id) {
                SpoolCardView(
                    spool: spool,
                    locationName: location.name,
                    compact: true,
                    isActive: model.activeSpoolIds.contains(spool.id),
                    onEdit: { onEdit(spool) },
                    onLoad: {},
                    onRetire: {},
                    onDelete: {},
                    onLogUsage: { onLogUsage(spool) }
                )
            } else {
                Text("Empty")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
