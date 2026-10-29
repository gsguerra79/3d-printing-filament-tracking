//
//  LeftColumnView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The window's left column: a succinct, color-coded printer-status card
//  spanning the full width, then the three stat numbers side by side (Total/
//  Open/Sealed — "Low Stock" was dropped as a meaningless metric), then the
//  Inventory Categories / Filament Types / Settings lists that drive the
//  bottom-right content area. This is the "actions and menu choices" column
//  from the spec — everything it selects is read by ContentAreaView via
//  `model.leftSelection`.
//

import SwiftUI

struct LeftColumnView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                printerStatusCard
                statBoxRow
            }
            .padding(14)

            Divider()

            List(selection: leftSelectionBinding) {
                Section("Inventory") {
                    ForEach(InventoryCategory.allCases) { category in
                        Label(category.rawValue, systemImage: category.systemImage)
                            .badge(model.count(for: category))
                            .tag(LeftMenuItem.category(category))
                    }
                }

                Section("Filament Types") {
                    ForEach(FilamentType.allCases) { type in
                        Label(type.rawValue, systemImage: type.systemImage)
                            .badge(model.count(for: type))
                            .tag(LeftMenuItem.filamentType(type))
                    }
                }

                Section("Settings") {
                    ForEach(SettingsPage.allCases) { page in
                        Label(page.rawValue, systemImage: page.systemImage)
                            .tag(LeftMenuItem.settings(page))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 240)
        .background(.quaternary.opacity(0.35))
    }

    private var leftSelectionBinding: Binding<LeftMenuItem?> {
        Binding(
            get: { model.leftSelection },
            set: { newValue in if let newValue { model.leftSelection = newValue } }
        )
    }

    private var statBoxRow: some View {
        HStack(spacing: 8) {
            statBox(title: "Total", value: model.totalCount, tint: .accentColor, category: .all)
            statBox(title: "Open", value: model.openCount, tint: .orange, category: .open)
            statBox(title: "Sealed", value: model.sealedCount, tint: .green, category: .sealed)
        }
    }

    private func statBox(title: String, value: Int, tint: Color, category: InventoryCategory) -> some View {
        Button {
            model.leftSelection = .category(category)
        } label: {
            VStack(alignment: .center, spacing: 4) {
                Text("\(value)")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(model.leftSelection == .category(category) ? tint : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    /// A full-width, succinct, color-coded printer status readout — moved
    /// here (out of the persistent header) so it reads at a glance without
    /// competing with the CFS panel's own visual weight.
    private var printerStatusCard: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(statusText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// "Printing" (checked first) overrides the plain connection-state
    /// colors/text below with a distinct blue while a print is actually
    /// running, so a glance at the left column tells connected-but-idle
    /// apart from actively-printing rather than showing the same green
    /// "Connected" for both.
    private var statusColor: Color {
        if model.printerSync?.isPrinting == true { return .blue }
        switch model.printerSync?.connectionState ?? .disconnected {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var statusText: String {
        if model.printerSync?.isPrinting == true { return "Printing" }
        switch model.printerSync?.connectionState ?? .disconnected {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .failed: return "Connection Failed"
        }
    }
}
