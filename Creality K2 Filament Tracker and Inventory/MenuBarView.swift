//
//  MenuBarView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Quick-glance content for the menu bar icon: printer connection status at
//  a glance, then what's loaded right now — each row shows the same
//  color-coded weight bar and location as the main window's cards (just
//  without the edit menu, since this is a glance, not an editing surface).
//

import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            printerStatusRow

            Divider()

            Text("Loaded Spools")
                .font(.headline)

            if model.loadedSpools.isEmpty {
                Text("Nothing currently loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.loadedSpools) { spool in
                        loadedSpoolRow(spool)
                    }
                }
            }

            Divider()

            Button("Open Filament Tracker") {
                // Restore the Dock icon (AppDelegate hides it once the last
                // window closes) before reopening the window itself, so the
                // two stay in sync -- window open means Dock icon visible.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    // MARK: - Printer status

    private var printerStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout.weight(.semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch model.printerSync?.connectionState ?? .disconnected {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch model.printerSync?.connectionState ?? .disconnected {
        case .connected: return "Printer Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Printer Disconnected"
        case .failed: return "Connection Failed"
        }
    }

    // MARK: - Loaded spool rows

    private func loadedSpoolRow(_ spool: Spool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: spool.colorHex))
                    .frame(width: 10, height: 10)
                Text("\(spool.brand) \(spool.colorName)")
                    .font(.callout)
                    .lineLimit(1)
                if model.activeSpoolIds.contains(spool.id) {
                    Text("● Printing")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 4)
                Text("\(spool.remainingWeightG)g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(barColor(for: spool))
                        .frame(width: geo.size.width * CGFloat(percent(for: spool)) / 100)
                }
            }
            .frame(height: 4)

            Text(model.locationName(for: spool.locationId))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// Same 0-100 clamp as SpoolCardView's `percent` — kept here rather than
    /// shared since this view only ever needs it for one spool at a time and
    /// pulling in SpoolCardView's private computed properties isn't possible
    /// across files anyway.
    private func percent(for spool: Spool) -> Int {
        guard spool.originalWeightG > 0 else { return 0 }
        let raw = Double(spool.remainingWeightG) / Double(spool.originalWeightG) * 100
        return max(0, min(100, Int(raw.rounded())))
    }

    /// Same green/amber/red thresholds as SpoolCardView's weight bar.
    private func barColor(for spool: Spool) -> Color {
        let value = percent(for: spool)
        if value >= 50 { return .green }
        if value >= 10 { return .orange }
        return .red
    }
}

#Preview {
    MenuBarView()
        .environment(AppModel())
}
