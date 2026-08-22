//
//  RecentUsageView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The "Recent Usage" feed — mirrors renderUsage() in the old web app
//  (last 8 usage_events, newest first, each showing grams/spool/date).
//

import SwiftUI

struct RecentUsageView: View {
    var events: [UsageEventDisplay]

    private var shown: [UsageEventDisplay] { Array(events.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Usage")
                .font(.title3.weight(.semibold))

            if shown.isEmpty {
                Text("No usage logged yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: event.colorHex))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(event.gramsUsed)g – \(event.brand) \(event.colorName)")
                                    .font(.callout)
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
                        .padding(.vertical, 6)
                        if index < shown.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
