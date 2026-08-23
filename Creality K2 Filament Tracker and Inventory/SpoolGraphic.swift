//
//  SpoolGraphic.swift
//  Creality K2 Filament Tracker and Inventory
//
//  A faithful port of the original web app's hand-drawn spool icon
//  (`spoolIconSvg()` / `.cfs-spool-icon` in the old app.js/styles.css) —
//  a layered rear disc, colored wound-filament body, front disc + hub, and
//  two highlight strokes — drawn with a SwiftUI `Canvas` instead of the
//  simplified two-circle "donut" this used to be. Every coordinate below is
//  taken directly from the old SVG's 82x96 viewBox and paths, just replayed
//  through `Path`/`Canvas` instead of markup, so it reads as a real spool of
//  filament rather than an abstract dot.
//

import SwiftUI

struct SpoolGraphic: View {
    var colorHex: String
    /// Treated as the icon's height; width is derived from the original
    /// SVG's fixed 82:96 aspect ratio so the shape never distorts.
    var diameter: CGFloat = 44

    private static let viewBoxWidth: CGFloat = 82
    private static let viewBoxHeight: CGFloat = 96

    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / Self.viewBoxWidth
            let scaleY = size.height / Self.viewBoxHeight
            let lineScale = (scaleX + scaleY) / 2

            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scaleX, y: y * scaleY)
            }
            func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(
                    x: (cx - rx) * scaleX, y: (cy - ry) * scaleY,
                    width: rx * 2 * scaleX, height: ry * 2 * scaleY
                ))
            }

            let spoolColor = Color(hex: colorHex)

            // Ground shadow.
            context.fill(ellipse(cx: 39, cy: 91, rx: 29, ry: 4), with: .color(.black.opacity(0.16)))

            // Rear disc (the far side of the reel, mostly hidden behind the
            // wound filament — just a dark rim showing at the edges).
            let rear = ellipse(cx: 20, cy: 48, rx: 20, ry: 45)
            context.fill(rear, with: .color(Self.rearFill))
            context.stroke(rear, with: .color(Self.rearStroke), lineWidth: 3 * lineScale)

            // The wound filament body itself — the one element tinted by
            // the spool's actual color.
            var filamentBody = Path()
            filamentBody.move(to: pt(20, 12))
            filamentBody.addLine(to: pt(58, 12))
            filamentBody.addCurve(to: pt(58, 84), control1: pt(64, 28), control2: pt(64, 68))
            filamentBody.addLine(to: pt(20, 84))
            filamentBody.addCurve(to: pt(20, 12), control1: pt(8, 68), control2: pt(8, 28))
            filamentBody.closeSubpath()
            context.fill(filamentBody, with: .color(spoolColor))
            context.stroke(filamentBody, with: .color(spoolColor.mix(with: .black, by: 0.38)), lineWidth: 2 * lineScale)

            // Front outer disc + inner face (the near side of the reel,
            // with the filament wound around its rim).
            let frontOuter = ellipse(cx: 58, cy: 48, rx: 20, ry: 45)
            context.fill(frontOuter, with: .color(Self.frontOuterFill))
            context.stroke(frontOuter, with: .color(Self.frontOuterStroke), lineWidth: 3.8 * lineScale)

            let frontFace = ellipse(cx: 58, cy: 48, rx: 15, ry: 36)
            context.fill(frontFace, with: .color(Self.frontFaceFill))
            context.stroke(frontFace, with: .color(Self.frontFaceStroke), lineWidth: 1.2 * lineScale)

            // Two soft highlight strokes that sell the roundness.
            var edgeHighlight = Path()
            edgeHighlight.move(to: pt(50, 6))
            edgeHighlight.addCurve(to: pt(78, 48), control1: pt(67, 6), control2: pt(78, 25))
            edgeHighlight.addCurve(to: pt(50, 90), control1: pt(78, 71), control2: pt(67, 90))
            context.stroke(edgeHighlight, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1.8 * lineScale, lineCap: .round))

            var sideHighlight = Path()
            sideHighlight.move(to: pt(21, 14))
            sideHighlight.addLine(to: pt(56, 14))
            context.stroke(sideHighlight, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1.8 * lineScale, lineCap: .round))

            // Center hub.
            let hubRim = ellipse(cx: 58, cy: 48, rx: 10, ry: 19)
            context.fill(hubRim, with: .color(Self.hubRimFill))
            context.stroke(hubRim, with: .color(Self.hubRimStroke), lineWidth: 2.2 * lineScale)

            let hub = ellipse(cx: 58, cy: 48, rx: 7, ry: 14)
            context.fill(hub, with: .color(Self.hubFill))
            context.stroke(hub, with: .color(Self.hubStroke), lineWidth: 2.4 * lineScale)
        }
        .frame(width: diameter * (Self.viewBoxWidth / Self.viewBoxHeight), height: diameter)
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    // Fixed dark-plastic tones straight from the old app's CSS — these
    // represent the physical reel material, not UI chrome, so they stay
    // constant regardless of light/dark appearance (same reasoning as a
    // photo of a real spool not changing color with the system theme).
    private static let rearFill = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x17 / 255)
    private static let rearStroke = Color(red: 0x34 / 255, green: 0x36 / 255, blue: 0x37 / 255)
    private static let frontOuterFill = Color(red: 0x15 / 255, green: 0x16 / 255, blue: 0x17 / 255)
    private static let frontOuterStroke = Color(red: 0x0c / 255, green: 0x0d / 255, blue: 0x0e / 255)
    private static let frontFaceFill = Color(red: 0x2c / 255, green: 0x2e / 255, blue: 0x2f / 255)
    private static let frontFaceStroke = Color(red: 0x3f / 255, green: 0x42 / 255, blue: 0x44 / 255)
    private static let hubFill = Color(red: 0x05 / 255, green: 0x05 / 255, blue: 0x05 / 255)
    private static let hubStroke = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255)
    private static let hubRimFill = Color(red: 0x20 / 255, green: 0x22 / 255, blue: 0x23 / 255)
    private static let hubRimStroke = Color(red: 0x11 / 255, green: 0x12 / 255, blue: 0x13 / 255)
}

#Preview {
    HStack(spacing: 16) {
        SpoolGraphic(colorHex: "#ff0000")
        SpoolGraphic(colorHex: "#006fd6", diameter: 60)
        SpoolGraphic(colorHex: "#111111", diameter: 32)
    }
    .padding()
}
