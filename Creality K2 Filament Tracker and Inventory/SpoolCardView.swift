//
//  SpoolCardView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  A single spool card — mirrors createSpoolCard() in the old web app,
//  including the color-coded weight bar (green >=50%, amber 10-49%,
//  red <10%) and the status/location tags. Comes in two sizes: `.regular`
//  for the inventory grid, `.large` for the always-visible CFS/External
//  Holder cards in the persistent header, which are deliberately bigger
//  (larger icon, larger type) since that panel never leaves the screen. The
//  quick-action menu is deliberately just Load/Unload/Retire/Edit — Log
//  Usage and Delete both live on the spool's detail page instead, reached
//  via Edit, rather than crowding this menu.
//
//  `.large` also fills its full proposed height (`Size.fillsHeight`), not
//  just its natural content height — this is what CFSPanelView's fixed-size
//  grid cells actually depend on. A card's own natural content (icon +
//  header + weight bar + tags) is shorter than the 180pt cell CFSPanelView
//  gives it, so without filling height this card's own background/border
//  would render at its own smaller natural size, floating top-aligned
//  inside the taller cell with blank space below it — while CFSPanelView's
//  Empty-slot and Recent-Usage boxes (which already fill their full
//  proposed size) would render as a full, taller box right next to it. Same
//  outer *allocated* space, visibly different *painted* box — which is
//  exactly what "the cards aren't the same size" was reporting. `.regular`
//  (the plain inventory grid) keeps natural content-height sizing, since
//  nothing there depends on filling a fixed-height cell.
//
//  Filling the background is only half of "not empty-looking" though — the
//  content itself (icon/header, weight bar, tag row) still needs to spread
//  across that filled height rather than cluster at the top with blank
//  background below it. So for `.large` the fixed `spacing: 10` between
//  those three sections becomes flexible `Spacer`s instead, which only do
//  anything once the VStack around them is actually proposed the full card
//  height (via `fillsHeight` above) to expand into. `.regular` keeps the
//  original fixed spacing — it was never asked to fill anything.
//

import SwiftUI

struct SpoolCardView: View {
    enum Size {
        case regular
        case large

        var iconDiameter: CGFloat {
            switch self {
            case .regular: return 44
            case .large: return 80
            }
        }

        var titleFont: Font {
            switch self {
            case .regular: return .headline
            case .large: return .title3.weight(.semibold)
            }
        }

        var padding: CGFloat {
            switch self {
            case .regular: return 12
            case .large: return 16
            }
        }

        var barHeight: CGFloat {
            switch self {
            case .regular: return 6
            case .large: return 8
            }
        }

        /// Whether this card should stretch to fill all the height it's
        /// given rather than sizing to its own natural content — see the
        /// file header comment for why `.large` needs this.
        var fillsHeight: Bool {
            switch self {
            case .regular: return false
            case .large: return true
            }
        }
    }

    let spool: Spool
    var locationName: String
    var size: Size = .regular
    var isActive: Bool = false
    var onEdit: () -> Void
    var onLoad: () -> Void
    var onUnload: () -> Void
    var onRetire: () -> Void

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
        VStack(alignment: .leading, spacing: size.fillsHeight ? 0 : 10) {
            HStack(alignment: .top, spacing: 10) {
                SpoolGraphic(colorHex: spool.colorHex, diameter: size.iconDiameter)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(spool.brand) \(spool.colorName)")
                        .font(size.titleFont)
                        .lineLimit(1)
                    Text(spool.material)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Load…", systemImage: "tray.and.arrow.down", action: onLoad)
                    Button("Unload", systemImage: "tray.and.arrow.up", action: onUnload)
                    Button("Retire", systemImage: "archivebox", action: onRetire)
                    Button("Edit…", systemImage: "pencil", action: onEdit)
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if size.fillsHeight {
                Spacer(minLength: 8)
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
                .frame(height: size.barHeight)
                Text("\(spool.remainingWeightG)g of \(spool.originalWeightG)g (\(percent)%)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if size.fillsHeight {
                Spacer(minLength: 8)
            }

            HStack(spacing: 6) {
                tag(spool.status.rawValue.capitalized, tint: statusTint)
                tag(locationName.isEmpty ? "No location" : locationName, tint: .secondary)
                if isActive {
                    tag("In use", tint: .green)
                }
            }
        }
        .padding(size.padding)
        .frame(maxWidth: .infinity, maxHeight: size.fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
