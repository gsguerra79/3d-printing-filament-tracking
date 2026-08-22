//
//  LogUsageSheet.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The "Log Usage" card action's dialog — mirrors openUsageDialog() in the
//  old web app: manually record a chunk of filament used against a spool.
//  Unlike automatic printer tracking, a manual entry that zeroes the spool
//  out is allowed to retire it immediately (see SpoolEditing.logUsage()).
//

import SwiftUI

struct LogUsageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let spool: Spool
    var onLog: (Int, String, String) -> Void

    @State private var grams: Int = 0
    @State private var project: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(spool.brand) \(spool.colorName) — \(spool.remainingWeightG)g remaining")
                        .foregroundStyle(.secondary)
                }
                Section("Usage") {
                    HStack {
                        Text("Grams used")
                        Spacer()
                        TextField("grams", value: $grams, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                    TextField("Project", text: $project)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Log Usage")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        onLog(grams, project, notes)
                        dismiss()
                    }
                    .disabled(grams <= 0)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}
