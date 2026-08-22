//
//  Creality_K2_Filament_Tracker_and_InventoryApp.swift
//  Creality K2 Filament Tracker and Inventory
//

import SwiftUI

@main
struct Creality_K2_Filament_Tracker_and_InventoryApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Filament Inventory") {
            ContentView()
                .environmentObject(model)
        }

        MenuBarExtra("Filament", systemImage: "printer.fill") {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
