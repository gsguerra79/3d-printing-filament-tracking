//
//  LoadSpoolPopoverView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The "Load" action's content — now a small popover anchored to the
//  detail inspector's toolbar button instead of a separate modal sheet.
//  Mirrors openLoadDialog()/loadableLocations() in the old web app: pick a
//  CFS slot or the external holder to move an existing spool into.
//

import SwiftUI

struct LoadSpoolPopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let spool: Spool
    var onLoad: (Int64) -> Void

    @State private var selectedLocationId: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Load \(spool.brand) \(spool.colorName)")
                .font(.headline)
            Text("\(spool.remainingWeightG)g remaining")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Load into", selection: $selectedLocationId) {
                ForEach(model.loadableLocations) { location in
                    Text(location.name).tag(Optional(location.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Load") {
                    if let id = selectedLocationId { onLoad(id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedLocationId == nil)
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear {
            selectedLocationId = model.loadableLocations.first(where: { $0.id == spool.locationId })?.id
                ?? model.loadableLocations.first?.id
        }
    }
}
