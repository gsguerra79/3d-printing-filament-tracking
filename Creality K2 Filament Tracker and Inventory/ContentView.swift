//
//  ContentView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The main dashboard — rebuilt to match the information architecture and
//  functionality of the original web app (metrics row, CFS/external-holder
//  panel, printer sync panel, filterable inventory grid with full spool
//  cards, recent-usage feed, and Add/Edit/Load/Log-Usage dialogs) rather
//  than the earlier read-only placeholder list. Restyled with native macOS
//  materials and system colors instead of copying the web app's dark/teal
//  palette.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var showingAddSheet = false
    @State private var editingSpool: Spool?
    @State private var loadingSpool: Spool?
    @State private var loggingUsageSpool: Spool?

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = model.loadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if let note = model.migrationNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let actionError = model.actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                MetricsRowView(
                    total: model.totalCount,
                    open: model.openCount,
                    sealed: model.sealedCount,
                    low: model.lowStockCount
                )

                printerPanel(model: model)

                CFSPanelView(
                    onEdit: { editingSpool = $0 },
                    onLogUsage: { loggingUsageSpool = $0 }
                )

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Inventory")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("\(model.filteredSpools.count) spool\(model.filteredSpools.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    FiltersBarView(
                        searchText: $model.searchText,
                        materialFilter: $model.materialFilter,
                        locationFilter: $model.locationFilter,
                        statusFilter: $model.statusFilter,
                        materials: model.availableMaterials,
                        locations: model.locations
                    )

                    if model.filteredSpools.isEmpty {
                        Text("No matching spools")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(model.filteredSpools) { spool in
                                SpoolCardView(
                                    spool: spool,
                                    locationName: model.locationName(for: spool.locationId),
                                    isActive: model.activeSpoolIds.contains(spool.id),
                                    onEdit: { editingSpool = spool },
                                    onLoad: { loadingSpool = spool },
                                    onRetire: { model.retireSpool(spool) },
                                    onDelete: { model.deleteSpool(spool) },
                                    onLogUsage: { loggingUsageSpool = spool }
                                )
                            }
                        }
                    }
                }

                Divider()

                RecentUsageView(events: model.usageEvents)
            }
            .padding(20)
        }
        .frame(minWidth: 980, minHeight: 720)
        .navigationTitle("Filament Inventory")
        .toolbar {
            ToolbarItem {
                Button {
                    model.reload()
                    model.refreshCrealityCatalog()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Spool", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            SpoolEditorSheet(existing: nil) { draft in
                model.createSpool(draft)
            }
            .environment(model)
        }
        .sheet(item: $editingSpool) { spool in
            SpoolEditorSheet(existing: spool) { draft in
                model.updateSpool(id: spool.id, draft: draft)
            }
            .environment(model)
        }
        .sheet(item: $loadingSpool) { spool in
            LoadSpoolSheet(spool: spool) { locationId in
                model.loadSpool(spool, intoLocationId: locationId)
            }
            .environment(model)
        }
        .sheet(item: $loggingUsageSpool) { spool in
            LogUsageSheet(spool: spool) { grams, project, notes in
                model.logUsage(spoolId: spool.id, grams: grams, project: project, notes: notes)
            }
        }
    }

    @ViewBuilder
    private func printerPanel(model: AppModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Printer Sync")
                .font(.title3.weight(.semibold))

            PrinterStatusView(
                connectionState: model.printerSync?.connectionState ?? .disconnected,
                lastSyncMessage: model.printerSync?.lastSyncMessage ?? "",
                lastUsageMessage: model.printerSync?.lastUsageMessage ?? "",
                addressDraft: Binding(
                    get: { model.printerAddressDraft },
                    set: { model.printerAddressDraft = $0 }
                ),
                onSave: { model.savePrinterAddressAndReconnect() }
            )

            if let count = model.settings["creality_catalog_count"] {
                Text("\(count) Creality filament profile\(count == "1" ? "" : "s") on file")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let message = model.crealityCatalogMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
