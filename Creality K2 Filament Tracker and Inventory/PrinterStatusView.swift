//
//  PrinterStatusView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Small status/control panel for the live Moonraker websocket connection:
//  shows whether we're connected, lets you edit the printer's address, and
//  shows the last sync outcome (including "unmatched slot" warnings, same
//  as the old app surfaced).
//

import SwiftUI

struct PrinterStatusView: View {
    let connectionState: MoonrakerClient.ConnectionState
    let lastSyncMessage: String
    let lastUsageMessage: String
    @Binding var addressDraft: String
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.headline)
            }

            HStack {
                TextField("Printer address, e.g. 192.168.5.16:4408", text: $addressDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Connect", action: onSave)
                    .disabled(addressDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Always present (never conditionally inserted/removed) and
            // pinned to a fixed line count via `reservesSpace` — a status
            // message that pops in/out or grows/shrinks the view as its text
            // changes length causes the whole window to jitter, since
            // WindowGroup by default sizes itself to its content. Truncating
            // instead of reflowing keeps this panel's height constant no
            // matter what text comes through.
            Text(lastSyncMessage.isEmpty ? " " : lastSyncMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)

            Text(lastUsageMessage.isEmpty ? " " : lastUsageMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch connectionState {
        case .connected: return "Printer connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Printer disconnected"
        case .failed(let message): return "Connection failed: \(message)"
        }
    }
}
