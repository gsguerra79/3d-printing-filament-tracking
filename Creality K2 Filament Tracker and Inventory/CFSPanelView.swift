//
//  CFSPanelView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The CFS tray grid + external spool holder + a recent-usage summary —
//  mirrors renderCfs() / renderExternalHolder() in the old web app, plus a
//  new "last 4 tracked usage" card. All six cells are laid out as ONE
//  `LazyVGrid` with 3 fixed columns, so every cell (the 4 CFS slots, the
//  recent-usage card, and the External Spool card) shares the same grid
//  row/column sizing — nothing is placed in a separate HStack or vertically
//  centered against the others. Row 1 is CFS Slot 1 / CFS Slot 2 / Recent
//  Usage; row 2 is CFS Slot 3 / CFS Slot 4 / External Spool Holder, so the
//  External card lines up with the bottom two CFS cards instead of floating
//  centered across both rows.
//
//  All six cells are built through the single `gridCard(label:content:)`
//  helper below, which applies the exact same label style and the exact
//  same `.frame(width:height:).clipped()` treatment to every cell — not six
//  independent call sites that each happen to use the same numbers.
//
//  The actual root cause of "the cards aren't the same size" (found after
//  the outer-frame numbers were already identical and it was STILL
//  happening): the outer allocated space was identical, but a loaded
//  `SpoolCardView`'s own background/border only ever sized itself to its
//  natural content height (~160pt) — shorter than this panel's 180pt cell —
//  while the Empty-slot placeholder and the Recent Usage box both
//  explicitly fill 100% of their proposed space. So a loaded card's visible
//  bordered box floated smaller, top-aligned, with invisible blank space
//  below it inside its cell, right next to a fully-filled Empty/Usage box —
//  same allocation, different painted size. Fixed at the source:
//  `SpoolCardView.Size.large` now also fills its full proposed height (see
//  `fillsHeight` in SpoolCardView.swift), so a loaded card's background
//  stretches to the exact same 230x180 box as everything else in this
//  panel. `.regular` (the plain inventory grid) is unaffected.
//
//  Every cell also now gets the exact same border — color and weight — via
//  the single `cardBorder` view below, applied identically whether the cell
//  is a loaded card, an empty slot, or the Recent Usage box.
//
//  Sized close to what a `.large`-size SpoolCardView actually needs
//  (~230x180) rather than padded out further, so this panel doesn't eat
//  more vertical space than the bigger cards actually require.
//
//  The panel's own background stretches to fill the full available width
//  (`.frame(maxWidth: .infinity, alignment: .leading)` around the padded
//  content, applied before `.background`) so its edges line up with the
//  content area below it, rather than sizing to just its own intrinsic
//  content width.
//

import SwiftUI

struct CFSPanelView: View {
    @Environment(AppModel.self) private var model

    var onEdit: (Spool) -> Void
    var onLoad: (Spool) -> Void
    var onUnload: (Spool) -> Void
    var onRetire: (Spool) -> Void

    private static let cardWidth: CGFloat = 230
    private static let cardHeight: CGFloat = 180

    private enum PanelCell: Identifiable {
        case location(Location)
        case recentUsage

        var id: String {
            switch self {
            case .location(let location): return "loc-\(location.id)"
            case .recentUsage: return "recent-usage"
            }
        }
    }

    private var cfsSlots: [Location] {
        model.cfsLocations.filter { $0.name.hasPrefix("CFS Slot") }
    }

    private var externalLocation: Location? {
        model.cfsLocations.first { $0.name == "External Spool Holder" }
    }

    /// Row 1: first two CFS slots, then the Recent Usage card. Row 2: the
    /// remaining CFS slots, then External — so External always lines up
    /// with the bottom row and Recent Usage always lines up with the top
    /// row, regardless of how many CFS slots exist.
    private var cells: [PanelCell] {
        let slots = cfsSlots
        var result = slots.prefix(2).map { PanelCell.location($0) }
        result.append(.recentUsage)
        result.append(contentsOf: slots.dropFirst(2).map { PanelCell.location($0) })
        if let externalLocation {
            result.append(.location(externalLocation))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CFS & External Holder")
                .font(.title3.weight(.semibold))

            LazyVGrid(
                columns: [
                    GridItem(.fixed(Self.cardWidth), spacing: 14),
                    GridItem(.fixed(Self.cardWidth), spacing: 14),
                    GridItem(.fixed(Self.cardWidth), spacing: 14),
                ],
                spacing: 14
            ) {
                ForEach(cells) { cell in
                    switch cell {
                    case .location(let location):
                        slotCard(for: location)
                    case .recentUsage:
                        recentUsageCard
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The single place every grid cell's outer size is decided: a caption
    /// label above a fixed `cardWidth` x `cardHeight` box, clipped to that
    /// box. Every one of the six cells in this panel is built by calling
    /// this same function — see the file header comment for why that
    /// matters more than it looks like it should.
    @ViewBuilder
    private func gridCard(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            content()
                .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .topLeading)
                .clipped()
        }
    }

    private func slotCard(for location: Location) -> some View {
        gridCard(label: location.name) {
            if let spool = model.spoolLoaded(atLocationId: location.id) {
                SpoolCardView(
                    spool: spool,
                    locationName: location.name,
                    size: .large,
                    isActive: model.activeSpoolIds.contains(spool.id),
                    onEdit: { onEdit(spool) },
                    onLoad: { onLoad(spool) },
                    onUnload: { onUnload(spool) },
                    onRetire: { onRetire(spool) }
                )
            } else {
                Text("Empty")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(cardBorder)
            }
        }
    }

    /// The last 8 tracked usage events (most recent first — same ordering
    /// `fetchRecentUsageEvents` already returns). Each row: the date logged
    /// (MM/DD/YY), the spool's color swatch, its color name next to the
    /// swatch, then its Name field (crealityName — falls back to material if
    /// a spool predates having one set), then grams used. Rows are spaced
    /// with flexible `Spacer`s between them rather than a fixed gap, so they
    /// distribute evenly across the card's full height instead of clumping
    /// at the top with blank space left below.
    private var recentUsageCard: some View {
        gridCard(label: "Recent Usage") {
            let recent = Array(model.usageEvents.prefix(8))
            Group {
                if recent.isEmpty {
                    VStack {
                        Spacer(minLength: 0)
                        Text("No usage tracked yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, event in
                            usageRow(event)
                            if index != recent.count - 1 {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(cardBorder)
        }
    }

    /// The exact same border every card in this panel gets — same color,
    /// same weight — whether it's a loaded `SpoolCardView` (which draws this
    /// itself), an empty slot, or the Recent Usage card. Defined once here
    /// so "same border" is guaranteed by construction rather than by three
    /// separate call sites happening to use matching literals.
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.separator, lineWidth: 1)
    }

    private func usageRow(_ event: UsageEventDisplay) -> some View {
        HStack(spacing: 5) {
            Text(dateText(for: event))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Circle()
                .fill(Color(hex: event.colorHex))
                .frame(width: 8, height: 8)
            Text("\(event.colorName) \(nameField(for: event))")
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(event.gramsUsed)g")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// The spool's Name field (crealityName) — falls back to its material
    /// if it doesn't have one set (older spools predating the Creality
    /// catalog linkage).
    private func nameField(for event: UsageEventDisplay) -> String {
        if let name = event.crealityName, !name.isEmpty {
            return name
        }
        return event.material
    }

    private static let isoParser = ISO8601DateFormatter()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy"
        return formatter
    }()

    /// The event's logged date as MM/DD/YY. `created_at` is always written
    /// via `ISO8601DateFormatter` (see SpoolEditing.swift/SpoolRepository.swift)
    /// so this should always parse; falls back to the raw string's date
    /// portion on the off chance it doesn't.
    private func dateText(for event: UsageEventDisplay) -> String {
        if let date = Self.isoParser.date(from: event.createdAt) {
            return Self.shortDateFormatter.string(from: date)
        }
        return String(event.createdAt.prefix(10))
    }
}
