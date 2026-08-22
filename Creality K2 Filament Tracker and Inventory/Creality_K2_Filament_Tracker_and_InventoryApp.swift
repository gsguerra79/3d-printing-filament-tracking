//
//  Creality_K2_Filament_Tracker_and_InventoryApp.swift
//  Creality K2 Filament Tracker and Inventory
//

import SwiftUI

@main
struct Creality_K2_Filament_Tracker_and_InventoryApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Filament Inventory") {
            ContentView()
                .environment(model)
        }

        MenuBarExtra("Filament", systemImage: "printer.fill") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
