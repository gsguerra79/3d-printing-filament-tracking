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
    private let usageEngine: UsageTrackingEngine

    private(set) var connectionState: MoonrakerClient.ConnectionState = .disconnected
    private(set) var lastSyncMessage: String = ""
    private(set) var lastUsageMessage: String = ""
    private(set) var latestCFSSlots: [ParsedCFSSlot] = []
    private(set) var latestExternalSlot: ParsedCFSSlot?

    /// Moonraker only pushes the objects that changed in a given
    /// `notify_status_update`, not the full subscribed set every time — so
    /// usage tracking (which needs box + print_stats + virtual_sdcard
    /// together) keeps a merged view of the latest known value for each
    /// subscribed object rather than reparsing a single partial push.
    private var latestStatus: [String: Any] = [:]

    /// Usage-tracking pushes can arrive several times a second while
    /// printing (Moonraker's normal cadence), but a single gram of filament
    /// takes much longer than that to extrude. Reacting to every push made
    /// the status message flap rapidly between "no new usage" and
    /// "accumulating" as sub-gram deltas came and went — correct math, just
    /// far too chatty a cadence to show. The old Python app polled the
    /// printer every 10 seconds for exactly this reason; this timer matches
    /// that cadence instead of driving usage checks off push frequency.
    private var usageTrackingTimer: Timer?
    private var hasSeenUsageRelevantPush = false

    /// Called after a successful sync so the owning AppModel can reload the
    /// spool list the UI is showing.
    var onInventoryChanged: (() -> Void)?

    init(repository: SpoolRepository) {
        self.repository = repository
        self.usageEngine = UsageTrackingEngine(repository: repository)
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
        usageTrackingTimer?.invalidate()
        usageTrackingTimer = nil
        hasSeenUsageRelevantPush = false
    }

    /// Forces the usage tracker to re-baseline against whatever print is
    /// currently active, discarding any in-progress delta/residual state.
    /// Not wired to any UI yet, but available for a future "reset usage
    /// tracking" action.
    func resetUsageTracking() {
        applyUsageTracking(reset: true)
    }

    private func handleStatusUpdate(_ status: [String: Any]) {
        Self.deepMerge(status, into: &latestStatus)
        if let box = status["box"] as? [String: Any] {
            latestCFSSlots = CFSStatusParser.parseCFSBox(box)
        }
        if let rack = status["filament_rack"] as? [String: Any] {
            latestExternalSlot = CFSStatusParser.parseExternalSlot(rack)
        }
        if !latestCFSSlots.isEmpty || latestExternalSlot != nil {
            syncToInventory()
        }
        if !hasSeenUsageRelevantPush,
           status["box"] != nil || status["print_stats"] != nil || status["virtual_sdcard"] != nil {
            // First relevant data: check right away so the baseline/status
            // message doesn't sit blank for up to 10s after connecting or
            // after a print starts. Every check after this one runs on the
            // timer below instead of on every push.
            hasSeenUsageRelevantPush = true
            applyUsageTracking()
            startUsageTrackingTimer()
        }
    }

    private func startUsageTrackingTimer() {
        usageTrackingTimer?.invalidate()
        usageTrackingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyUsageTracking()
            }
        }
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

    private func applyUsageTracking(reset: Bool = false) {
        let snapshot = UsageSnapshotParser.parse(latestStatus)
        do {
            let result = try usageEngine.apply(snapshot: snapshot, reset: reset)
            lastUsageMessage = result.message
            if result.deducted > 0 || result.rebalanced {
                onInventoryChanged?()
            }
        } catch {
            lastUsageMessage = "Usage tracking error: \(error.localizedDescription)"
        }
    }

    /// Merges a Moonraker status push into the running snapshot field by
    /// field instead of object by object. This matters because
    /// `notify_status_update` only includes the *fields that changed* within
    /// each object, not the whole object every time — e.g. a push touching
    /// only `print_stats.print_duration` while printing is normal and does
    /// NOT mean `filename`/`state` are gone. Replacing the whole object on
    /// every push (the previous behavior) made those fields flicker between
    /// present and missing on every unrelated field update, which showed up
    /// as the usage message flapping between real data and "no active print
    /// found" throughout a live print.
    private static func deepMerge(_ new: [String: Any], into existing: inout [String: Any]) {
        for (key, value) in new {
            if let newDict = value as? [String: Any], let existingDict = existing[key] as? [String: Any] {
                var merged = existingDict
                deepMerge(newDict, into: &merged)
                existing[key] = merged
            } else {
                existing[key] = value
            }
        }
    }
}
