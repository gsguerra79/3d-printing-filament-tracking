//
//  MetricsRowView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The Total/Open/Sealed/Low-Stock summary row — mirrors renderMetrics() in
//  the old web app (active = not retired and not in a retired-kind
//  location; low stock = active spools under 200g remaining).
//

import SwiftUI

struct MetricsRowView: View {
    var total: Int
    var open: Int
    var sealed: Int
    var low: Int

    var body: some View {
        HStack(spacing: 12) {
            tile("Total", value: total, tint: .primary)
            tile("Open", value: open, tint: .blue)
            tile("Sealed", value: sealed, tint: .green)
            tile("Low Stock", value: low, tint: low > 0 ? .orange : .secondary)
        }
    }

    private func tile(_ title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title.bold())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview {
    MetricsRowView(total: 12, open: 3, sealed: 7, low: 2)
        .padding()
}
