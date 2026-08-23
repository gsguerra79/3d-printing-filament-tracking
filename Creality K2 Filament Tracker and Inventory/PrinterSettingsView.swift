//
//  PrinterSettingsView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The sidebar's "Printer" destination — the connection form and Creality
//  catalog controls, split out of the old dashboard's always-visible panel
//  into their own screen now that Overview has a printer summary row.
//

import SwiftUI

struct PrinterSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            Text("Printer Connection")
                .font(.title2.weight(.semibold))
                .padding(16)

            Form {
                Section("Connection") {
                    PrinterStatusView(
                        connectionState: model.printerSync?.connectionState ?? .disconnected,
                        lastSyncMessage: model.printerSync?.lastSyncMessage ?? "",
                        lastUsageMessage: model.printerSync?.lastUsageMessage ?? "",
                        addressDraft: $model.printerAddressDraft,
                        onSave: { model.savePrinterAddressAndReconnect() }
                    )
                }

                Section("Creality Catalog") {
                    if let count = model.settings["creality_catalog_count"] {
                        LabeledContent("Profiles on file", value: count)
                    }
                    if let message = model.crealityCatalogMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh Creality Catalog") {
                        model.refreshCrealityCatalog()
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
