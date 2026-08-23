//
//  TrackingCorrectionsView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  New settings page: "Tracking Error Corrections / manual assignment".
//  Surfaces the latest printer-sync mismatch message (read-only — the
//  database never auto-acts on it, see conflictDescription in
//  SpoolRepository.swift) and every unresolved `pending_usage_events` row —
//  grams the printer reported using that couldn't be safely matched to a
//  spool automatically. Each row lets a person assign the grams to the
//  spool they know it came from, or discard it if it was spurious.
//

import SwiftUI

struct TrackingCorrectionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tracking Error Corrections")
                .font(.title2.weight(.semibold))
                .padding(16)

            List {
                if let message = model.settings["slot_sync_last_message"], !message.isEmpty {
                    Section("Last Printer Sync") {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(model.lastSyncConflictMessage != nil ? .orange : .secondary)
                    }
                }

                Section {
                    if model.pendingUsageEvents.isEmpty {
                        Text("No unresolved printer usage. Everything queued has been credited to a spool.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.pendingUsageEvents) { event in
                            PendingUsageRow(event: event)
                        }
                    }
                } header: {
                    Text("Unresolved Printer Usage")
                } footer: {
                    Text("These are grams the printer reported using from a CFS holder that couldn't be safely matched to a spool at the time — usually because nothing was marked loaded there yet. Assign each to the spool it actually came from, or discard it if it was spurious.")
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct PendingUsageRow: View {
    @Environment(AppModel.self) private var model

    let event: PendingUsageEvent

    @State private var selectedSpoolId: Int64?
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.gramsPending)g from \(event.slotName)")
                        .font(.subheadline.weight(.semibold))
                    Text(event.filename.isEmpty ? event.basis : event.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(formattedDate(event.createdAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !event.notes.isEmpty {
                Text(event.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Picker("Assign to", selection: $selectedSpoolId) {
                    Text("Choose a spool…").tag(Int64?.none)
                    ForEach(candidateSpools) { spool in
                        Text("\(spool.brand) \(spool.colorName)").tag(Optional(spool.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)

                Button("Assign") {
                    if let id = selectedSpoolId {
                        model.assignPendingUsage(event, toSpoolId: id)
                    }
                }
                .disabled(selectedSpoolId == nil)

                Spacer()

                Button("Discard", role: .destructive) {
                    confirmingDiscard = true
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Discard this queued usage without applying it?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                model.discardPendingUsage(event)
            }
        }
    }

    /// Retired spools are excluded — nothing left in them to deduct from.
    private var candidateSpools: [Spool] {
        model.spools
            .filter { $0.status != .retired }
            .sorted {
                if $0.brand != $1.brand {
                    return $0.brand.localizedStandardCompare($1.brand) == .orderedAscending
                }
                return $0.colorName.localizedStandardCompare($1.colorName) == .orderedAscending
            }
    }

    private func formattedDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return String(iso.prefix(10)) }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
