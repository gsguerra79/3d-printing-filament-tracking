//
//  Creality_K2_Filament_Tracker_and_InventoryApp.swift
//  Creality K2 Filament Tracker and Inventory
//

import SwiftUI

@main
struct Creality_K2_Filament_Tracker_and_InventoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        LoginItemManager.registerIfNeeded()
    }

    var body: some Scene {
        // Explicit id so MenuBarView's "Open Filament Tracker" action can
        // reliably reopen this exact window via `openWindow(id:)` even
        // after it's been fully closed (see AppDelegate.swift for the
        // matching Dock-icon-hiding half of this).
        WindowGroup("Filament Tracker v3.0", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    if let folder = model.projectFolder {
                        await model.refreshProjectCatalog(folder)
                    }
                }
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
