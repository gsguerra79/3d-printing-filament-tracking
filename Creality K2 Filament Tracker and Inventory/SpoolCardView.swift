//
//  SpoolCardView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  A single spool card, used both full-size in the inventory grid and in a
//  `compact` form inside the CFS slot panel — mirrors createSpoolCard() in
//  the old web app, including the color-coded weight bar
//  (green >=50%, amber 10-49%, red <10%) and the status/location tags.
//  Compact cards drop the Load/Retire/Delete actions (those slots are
//  normally managed by printer sync) but keep Edit, same as the original.
//

import SwiftUI

struct SpoolCardView: View {
    let spool: Spool
    var locationName: String
    var compact: Bool = false
    var isActive: Bool = false
    var onEdit: () -> Void
    var onLoad: () -> Void
    var onRetire: () -> Void
    var onDelete: () -> Void
    var onLogUsage: () -> Void

    private var percent: Int {
        guard spool.originalWeightG > 0 else { return 0 }
        let raw = Double(spool.remainingWeightG) / Double(spool.originalWeightG) * 100
        return max(0, min(100, Int(raw.rounded())))
    }

    private var barColor: Color {
        if percent >= 50 { return .green }
        if percent >= 10 { return .orange }
        return .red
    }

    private var statusTint: Color {
        switch spool.status {
        case .loaded: return .blue
        case .open: return .orange
        case .sealed: return .green
        case .retired: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .top, spacing: 10) {
                SpoolGraphic(colorHex: spool.colorHex, diameter: compact ? 34 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(spool.brand) \(spool.colorName)")
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .lineLimit(1)
                    Text(spool.material)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if compact {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Menu {
                        Button("Edit…", systemImage: "pencil", action: onEdit)
                        Button("Load…", systemImage: "tray.and.arrow.down", action: onLoad)
                        Button("Log Usage…", systemImage: "minus.circle", action: onLogUsage)
                        Divider()
                        Button("Retire", systemImage: "archivebox", action: onRetire)
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(barColor)
                            .frame(width: geo.size.width * CGFloat(percent) / 100)
                    }
                }
                .frame(height: 6)
                Text("\(spool.remainingWeightG)g of \(spool.originalWeightG)g (\(percent)%)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !compact {
                HStack(spacing: 6) {
                    tag(spool.status.rawValue.capitalized, tint: statusTint)
                    tag(locationName.isEmpty ? "No location" : locationName, tint: .secondary)
                    if isActive {
                        tag("In use", tint: .green)
                    }
                }
            } else if isActive {
                tag("In use", tint: .green)
            }
        }
        .padding(compact ? 8 : 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
