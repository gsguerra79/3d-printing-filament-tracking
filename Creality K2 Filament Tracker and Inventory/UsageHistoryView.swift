//
//  UsageHistoryView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The sidebar's "Usage History" destination — a full native list of every
//  logged usage event, replacing the old dashboard's 8-item "Recent Usage"
//  feed with a dedicated screen (the last few events still show inline on
//  the Overview screen for a quick glance).
//

import SwiftUI

struct UsageHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tracking Log")
                .font(.title2.weight(.semibold))
                .padding(16)

            List(model.usageEvents) { event in
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: event.colorHex)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(event.gramsUsed)g – \(event.brand) \(event.colorName)")
                        Text(subtitle(for: event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(formattedDate(event.createdAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .overlay {
                if model.usageEvents.isEmpty {
                    ContentUnavailableView(
                        "No Usage Logged",
                        systemImage: "clock",
                        description: Text("Usage events will appear here as you print.")
                    )
                }
            }
        }
    }

    private func subtitle(for event: UsageEventDisplay) -> String {
        if !event.project.isEmpty { return event.project }
        if !event.notes.isEmpty { return event.notes }
        return event.material
    }

    private func formattedDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return String(iso.prefix(10)) }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
