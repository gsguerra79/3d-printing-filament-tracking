//
//  AppDelegate.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Makes the Dock icon follow whether the main window is actually open —
//  visible in the Dock while it's open, gone from the Dock (but still
//  fully running, reachable from the menu bar) once it's closed. Plain
//  SwiftUI has no scene-level hook for "the last window just closed", so
//  this needs a real AppKit delegate hooked in via
//  `@NSApplicationDelegateAdaptor`.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Without this, closing the last window would quit the app entirely —
    /// SwiftUI's default for a window-based app. We want it to keep
    /// running in the menu bar instead, the same way MenuBarView's
    /// printer-sync/loaded-spools glance is meant to work with no window
    /// open at all.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // Dispatched async so this runs after the closing window is
        // actually removed from NSApp.windows — checking synchronously
        // inside willClose still sees the window that's in the middle of
        // closing and would think a window is still open when it isn't.
        DispatchQueue.main.async {
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
