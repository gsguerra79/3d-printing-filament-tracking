//
//  ContentView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The main window — a left column of actions/menu choices next to two
//  stacked right-hand panels: a persistent top strip (CFS + External Spool,
//  printer status — always visible, whatever's selected on the left) and a
//  bottom content area that switches between inventory card grids, settings
//  pages, and a pushed spool detail page with a native back button. See
//  LeftColumnView / PersistentHeaderView / ContentAreaView.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            LeftColumnView()

            Divider()

            VStack(spacing: 0) {
                PersistentHeaderView()

                Divider()
                    .padding(.top, 10)

                ContentAreaView()
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .safeAreaInset(edge: .top) {
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.red)
            }
        }
        .sheet(item: $model.editingSpool) { spool in
            SpoolEditorView(spool: spool)
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { newValue in if !newValue { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }
}

extension Color {
    /// Parses a "#rrggbb" hex string; falls back to gray on anything else.
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        value.removeAll { $0 == "#" }
        guard value.count == 6, let intValue = UInt32(value, radix: 16) else {
            self = .gray
            return
        }
        let r = Double((intValue >> 16) & 0xFF) / 255
        let g = Double((intValue >> 8) & 0xFF) / 255
        let b = Double(intValue & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
