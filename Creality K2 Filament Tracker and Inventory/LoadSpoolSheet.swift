//
//  LoadSpoolSheet.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The "Load" card action's dialog — mirrors openLoadDialog()/
//  loadableLocations() in the old web app: pick a CFS slot or the external
//  holder to move an existing spool into.
//

import SwiftUI

struct LoadSpoolSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let spool: Spool
    var onLoad: (Int64) -> Void

    @State private var selectedLocationId: Int64?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(spool.brand) \(spool.colorName) — \(spool.remainingWeightG)g remaining")
                        .foregroundStyle(.secondary)
                }
                Picker("Load into", selection: $selectedLocationId) {
                    ForEach(model.loadableLocations) { location in
                        Text(location.name).tag(Optional(location.id))
                    }
                }
                .pickerStyle(.inline)
            }
            .formStyle(.grouped)
            .navigationTitle("Load Spool")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Load") {
                        if let id = selectedLocationId {
                            onLoad(id)
                        }
                        dismiss()
                    }
                    .disabled(selectedLocationId == nil)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
        .onAppear {
            selectedLocationId = model.loadableLocations.first(where: { $0.id == spool.locationId })?.id
                ?? model.loadableLocations.first?.id
        }
    }
}
