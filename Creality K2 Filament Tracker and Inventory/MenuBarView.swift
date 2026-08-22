//
//  MenuBarView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Quick-glance content for the menu bar icon: what's loaded right now.
//  Printer connection status will be added once the websocket listener
//  (task: Build Moonraker websocket listener) is in place.
//

import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loaded Spools")
                .font(.headline)

            if model.loadedSpools.isEmpty {
                Text("Nothing currently loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.loadedSpools) { spool in
                    HStack {
                        Circle()
                            .fill(Color(hex: spool.colorHex))
                            .frame(width: 10, height: 10)
                        Text("\(spool.brand) \(spool.colorName)")
                            .font(.callout)
                        Spacer()
                        Text("\(spool.remainingWeightG)g")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Button("Open Filament Tracker") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}

#Preview {
    MenuBarView()
        .environment(AppModel())
}
