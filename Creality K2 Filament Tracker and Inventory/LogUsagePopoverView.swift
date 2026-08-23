//
//  LogUsagePopoverView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The "Log Usage" action's content — now a small popover anchored to the
//  detail inspector's toolbar button instead of a separate modal sheet.
//  Mirrors openUsageDialog() in the old web app: manually record a chunk of
//  filament used against a spool. Unlike automatic printer tracking, a
//  manual entry that zeroes the spool out is allowed to retire it
//  immediately (see SpoolEditing.logUsage()).
//

import SwiftUI

struct LogUsagePopoverView: View {
    @Environment(\.dismiss) private var dismiss

    let spool: Spool
    var onLog: (Int, String, String) -> Void

    @State private var grams: Int = 0
    @State private var project: String = ""
    @State private var notes: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log Usage")
                .font(.headline)
            Text("\(spool.brand) \(spool.colorName) — \(spool.remainingWeightG)g remaining")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Grams used")
                Spacer()
                TextField("grams", value: $grams, format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
            TextField("Project", text: $project)
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...4)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Log") {
                    onLog(grams, project, notes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(grams <= 0)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
