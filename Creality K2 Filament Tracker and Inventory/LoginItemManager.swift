//
//  LoginItemManager.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Replaces the old Python app's LaunchAgent
//  (`mac/com.gsguerra.filament-tracker.plist`, which set `RunAtLoad` so the
//  tracker process started automatically at login, plus a `KeepAlive` restart
//  policy for a headless background daemon) with the native macOS
//  equivalent for a real GUI app: `SMAppService.mainApp`.
//
//  `RunAtLoad` maps directly onto `SMAppService.mainApp.register()` — once
//  registered, the app launches automatically at login. The old plist's
//  `KeepAlive.SuccessfulExit = false` (restart on crash, but not on a clean
//  exit) has no equivalent here and isn't needed: that behavior existed
//  because the old app was a headless Flask server that was never supposed
//  to exit on its own. This is a normal windowed/menu-bar app now — if it
//  crashes, it behaves like any other Mac app (nothing auto-restarts it),
//  which is the expected, unsurprising behavior for something living in the
//  Dock and menu bar rather than a background daemon.
//
//  Unlike the old plist (manually copied into ~/Library/LaunchAgents and
//  manually removed to undo), a login item registered this way shows up
//  natively in System Settings -> General -> Login Items & Extensions,
//  where Gabriel can toggle it off/on directly with no in-app UI needed for
//  that.
//
//  Note: registration tracks the running app bundle's code signature and
//  location. It's expected to behave inconsistently while running an
//  Xcode debug build straight out of DerivedData (a path that changes
//  build-to-build) — this is meant to be verified once the app is actually
//  installed via Archive -> Export -> /Applications, not during ordinary
//  Cmd+R iteration.
//

import Foundation
import ServiceManagement

enum LoginItemManager {
    /// Registers this app to launch at login, matching the old LaunchAgent's
    /// `RunAtLoad`. Safe to call on every launch — a no-op if already
    /// registered or pending approval.
    static func registerIfNeeded() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled, .requiresApproval:
            return
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }

        do {
            try service.register()
        } catch {
            print("LoginItemManager: failed to register login item — \(error)")
        }
    }
}
