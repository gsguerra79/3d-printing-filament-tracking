//
//  Creality_K2_Filament_Tracker_and_InventoryApp.swift
//  Creality K2 Filament Tracker and Inventory
//

import SwiftUI

@main
struct Creality_K2_Filament_Tracker_and_InventoryApp: App {
    @State private var model = AppModel()

    init() {
        LoginItemManager.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup("Filament Tracker v2") {
            ContentView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(nsImage: MenuBarSpoolIcon.image)
                .accessibilityLabel("Filament Tracker")
        }
        .menuBarExtraStyle(.window)
    }
}
