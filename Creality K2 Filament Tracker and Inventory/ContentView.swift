//
//  ContentView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  First pass at the main window: a read-only table of the real spool
//  inventory (migrated from the old Python app's database) grouped by
//  status, so we can confirm the data layer works end-to-end before
//  layering on editing, Creality profile pickers, and printer sync.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List {
                if let error = model.loadError {
                    Section("Database") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                statusSection("Loaded", spools: model.loadedSpools, systemImage: "bolt.fill")
                statusSection("Open", spools: model.openSpools, systemImage: "circle.lefthalf.filled")
                statusSection("Sealed Stock", spools: model.sealedSpools, systemImage: "shippingbox.fill")
            }
            .navigationTitle("Filament Inventory")
            .toolbar {
                ToolbarItem {
                    Button {
                        model.reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        } detail: {
            @Bindable var model = model
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("\(model.spools.count) spools total")
                        .font(.title2)
                    Text("Database: \(FilamentDatabase.defaultDatabaseURL().path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let note = model.migrationNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }

                Divider()

                VStack(spacing: 8) {
                    Button {
                        model.refreshCrealityCatalog()
                    } label: {
                        Label("Refresh Creality Catalog", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if let count = model.settings["creality_catalog_count"] {
                        Text("\(count) Creality filament profiles on file")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message = model.crealityCatalogMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Divider()

                PrinterStatusView(
                    connectionState: model.printerSync?.connectionState ?? .disconnected,
                    lastSyncMessage: model.printerSync?.lastSyncMessage ?? "",
                    lastUsageMessage: model.printerSync?.lastUsageMessage ?? "",
                    addressDraft: $model.printerAddressDraft,
                    onSave: { model.savePrinterAddressAndReconnect() }
                )
            }
            .padding()
            .frame(maxWidth: 480)
        }
        // A default WindowGroup sizes itself to fit its content, and
        // re-derives that size whenever the content's ideal size changes —
        // so without an explicit floor here, a status message ticking
        // through different lengths during a live print made the whole
        // window visibly jitter as it kept auto-resizing. Fixing the status
        // text to a stable height (see PrinterStatusView) addresses the
        // root cause; this frame is a second line of defense so the window
        // itself has a stable size to fall back to.
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private func statusSection(_ title: String, spools: [Spool], systemImage: String) -> some View {
        if !spools.isEmpty {
            Section("\(title) (\(spools.count))") {
                ForEach(spools) { spool in
                    HStack {
                        Circle()
                            .fill(Color(hex: spool.colorHex))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
                        VStack(alignment: .leading) {
                            Text("\(spool.brand) — \(spool.colorName)")
                                .font(.body)
                            Text("\(spool.material) · \(model.locationName(for: spool.locationId)) · \(spool.remainingWeightG)g left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

extension Color {
    /// Parses a "#rrggbb" hex string; falls back to gray on anything else.
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        value.removeAll { $0 == "#" }
        guard value.count == 6, let intValue = UInt32(value, radix: 16) else {
            self = .gray
            return
        }
        let r = Double((intValue >> 16) & 0xFF) / 255
        let g = Double((intValue >> 8) & 0xFF) / 255
        let b = Double(intValue & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
