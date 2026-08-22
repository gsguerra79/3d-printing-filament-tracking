//
//  SpoolGraphic.swift
//  Creality K2 Filament Tracker and Inventory
//
//  A simplified native rendering of a filament spool used in the CFS slot
//  cards, in place of the old web app's detailed hand-drawn SVG. This isn't
//  a pixel port — it's the same idea (a colored spool with a visible hub)
//  expressed as plain SwiftUI shapes so it sits naturally alongside native
//  macOS materials instead of carrying over the dark-theme web illustration.
//

import SwiftUI

struct SpoolGraphic: View {
    var colorHex: String
    var diameter: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: colorHex))
                .frame(width: diameter, height: diameter)
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
            Circle()
                .fill(.background)
                .frame(width: diameter * 0.4, height: diameter * 0.4)
            Circle()
                .strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
                .frame(width: diameter * 0.4, height: diameter * 0.4)
        }
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 16) {
        SpoolGraphic(colorHex: "#ff0000")
        SpoolGraphic(colorHex: "#006fd6", diameter: 60)
        SpoolGraphic(colorHex: "#111111", diameter: 32)
    }
    .padding()
}
