//
//  PrinterSyncEngine.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Bridges the low-level MoonrakerClient to the inventory: parses each
//  status push into CFS/external-holder slot data and syncs it into the
//  database, then republishes a UI-friendly summary of what's currently in
//  the printer and whether we're even connected.
//

import Foundation
import Observation

@MainActor
@Observable
final class PrinterSyncEngine {
    private let client = MoonrakerClient()
    private let repository: SpoolRepository

    private(set) var connectionState: MoonrakerClient.ConnectionState = .disconnected
    private(set) var lastSyncMessage: String = ""
    private(set) var latestCFSSlots: [ParsedCFSSlot] = []
    private(set) var latestExternalSlot: ParsedCFSSlot?

    /// Called after a successful sync so the owning AppModel can reload the
    /// spool list the UI is showing.
    var onInventoryChanged: (() -> Void)?

    init(repository: SpoolRepository) {
        self.repository = repository
        client.onStatusUpdate = { [weak self] status in
            self?.handleStatusUpdate(status)
        }
        client.onStateChange = { [weak self] state in
            self?.connectionState = state
        }
    }

    func connect(baseURL: String) {
        client.connect(to: baseURL)
    }

    func disconnect() {
        client.disconnect()
        connectionState = .disconnected
    }

    private func handleStatusUpdate(_ status: [String: Any]) {
        if let box = status["box"] as? [String: Any] {
            latestCFSSlots = CFSStatusParser.parseCFSBox(box)
        }
        if let rack = status["filament_rack"] as? [String: Any] {
            latestExternalSlot = CFSStatusParser.parseExternalSlot(rack)
        }
        guard !latestCFSSlots.isEmpty || latestExternalSlot != nil else { return }
        syncToInventory()
    }

    private func syncToInventory() {
        do {
            lastSyncMessage = try repository.syncPrinterSlots(
                cfsSlots: latestCFSSlots,
                externalSlot: latestExternalSlot
            )
            onInventoryChanged?()
        } catch {
            lastSyncMessage = "Sync error: \(error.localizedDescription)"
        }
    }
}
