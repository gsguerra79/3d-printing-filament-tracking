//
//  MenuBarSpoolIcon.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Replaces the earlier 3D-printer gantry glyph (formerly
//  MenuBarPrinterIcon.swift) with a filament-spool glyph instead, per
//  Gabriel's request to make both app icons ("the app and menu bar")
//  actually look like the spool used throughout the rest of the app,
//  rather than a printer.
//
//  The design is a simplified head-on view of SpoolGraphic's front face:
//  a thick outer ring (the spool rim) with a filled hub dot in the center.
//  An earlier attempt reused SpoolGraphic's two-overlapping-ellipse
//  side-view silhouette (rear disc + front disc with a punched hub hole),
//  but at true 18x18 menu bar size that shape rendered lopsided and read
//  more like a crescent than a spool. Concentric circles are a much more
//  robust motif at tiny bitmap sizes — verified by rendering both designs
//  down to 18x18 and inspecting them pixel-by-pixel before choosing this
//  one.
//
//  Rendered once to a black-on-clear `NSImage` with `isTemplate = true`
//  rather than used as a live SwiftUI view directly in the menu bar — a
//  template image is what makes AppKit treat this exactly like a built-in
//  SF Symbol, automatically following light/dark menu bar appearance and
//  inverting to white when the menu is open/highlighted.
//

import AppKit
import SwiftUI

enum MenuBarSpoolIcon {
    /// The rendered template image — compute once, reuse for the life of
    /// the app (the menu bar icon never changes).
    static let image: NSImage = {
        let renderer = ImageRenderer(content: glyph)
        renderer.scale = 2 // render at 2x so it stays crisp on Retina displays
        let nsImage = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        nsImage.isTemplate = true
        return nsImage
    }()

    /// Drawn on a 24x24 grid, scaled down to an 18x18 menu bar glyph:
    /// a thick ring (spool rim) with a filled hub dot centered inside it.
    private static var glyph: some View {
        Canvas { context, size in
            let scale = size.width / 24
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            // Outer rim: a thick stroked circle.
            let outerRadius: CGFloat = 9.5 * scale
            let ringLineWidth: CGFloat = 2.6 * scale
            let ringRect = CGRect(
                x: center.x - outerRadius, y: center.y - outerRadius,
                width: outerRadius * 2, height: outerRadius * 2
            )
            context.stroke(Path(ellipseIn: ringRect), with: .color(.black), lineWidth: ringLineWidth)

            // Hub: a small filled circle in the center.
            let hubRadius: CGFloat = 3.2 * scale
            let hubRect = CGRect(
                x: center.x - hubRadius, y: center.y - hubRadius,
                width: hubRadius * 2, height: hubRadius * 2
            )
            context.fill(Path(ellipseIn: hubRect), with: .color(.black))
        }
        .frame(width: 18, height: 18)
    }
}
