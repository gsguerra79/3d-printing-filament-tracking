//
//  UsageTrackingEngine.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The orchestrating state machine that turns a PrintUsageSnapshot into
//  actual gram deductions against loaded spools. Direct port of
//  apply_printer_usage_snapshot() and its helpers from the original Python
//  app (choose_spool_for_part, allocate_usage_to_loaded_spools,
//  allocate_usage_for_snapshot, active_usage_spool_ids,
//  planned_part_gram_targets, reconcile_completed_multicolor_usage,
//  record_pending_usage).
//
//  Persistent state lives in the `settings` table under the same
//  usage_monitor_* keys the Python app used:
//    usage_monitor_signature       - "<filename>|<start_time>" of the print
//                                     we last saw usage for (detects a new
//                                     print starting so we can re-baseline)
//    usage_monitor_used_grams      - the snapshot's cumulative used_grams
//                                     as of the last poll (the baseline the
//                                     next poll's delta is measured against)
//    usage_monitor_residual_grams  - fractional grams carried over between
//                                     polls so whole-gram deductions don't
//                                     lose the remainder each time
//    usage_monitor_last_message    - human-readable status for the UI
//    usage_monitor_last_checked    - ISO timestamp of the last update
//    usage_monitor_active_spool_ids - comma-separated spool ids currently
//                                     being drawn from (for UI highlighting)
//

import Foundation

struct UsageApplyResult {
    var tracked: Bool
    var baseline: Bool = false
    var deducted: Int = 0
    var message: String
    var pendingGrams: Double = 0
    var queued: Bool = false
    var queuedGrams: Int = 0
    var slotName: String = ""
    var rebalanced: Bool = false
    var allocations: [(spoolId: Int64, label: String, grams: Int)] = []
}

@MainActor
final class UsageTrackingEngine {
    private let repository: SpoolRepository

    init(repository: SpoolRepository) {
        self.repository = repository
    }

    /// Mirrors apply_printer_usage_snapshot(). Call this on every status
    /// update that touches box/print_stats/virtual_sdcard; it's cheap and
    /// idempotent when there's nothing new to record.
    @discardableResult
    func apply(snapshot: PrintUsageSnapshot, reset: Bool = false) throws -> UsageApplyResult {
        guard !snapshot.signature.isEmpty else {
            // Temporary diagnostic detail (2026-08-22): this printer's
            // firmware may not expose print_stats/virtual_sdcard the way
            // stock Klipper does, so surface exactly what we did see instead
            // of guessing. Remove the parenthetical once usage tracking is
            // confirmed working against a real print.
            let diagnostic = "(print_stats key: \(snapshot.hasPrintStatsKey), " +
                "virtual_sdcard key: \(snapshot.hasVirtualSDCardKey), " +
                "state=\"\(snapshot.state)\" filename=\"\(snapshot.filename)\" " +
                "progress=\(snapshot.progress) plannedTotalG=\(snapshot.plannedTotalGrams) " +
                "usedG=\(snapshot.usedGrams) mm=\(snapshot.filamentUsedMM))"
            let message = "No active or recent print found. \(diagnostic)"
            try repository.setSetting("usage_monitor_last_message", message)
            try repository.setSetting("usage_monitor_active_spool_ids", "")
            return UsageApplyResult(tracked: false, message: message)
        }

        let lastSignature = try repository.getSetting("usage_monitor_signature") ?? ""
        let lastUsedGrams = Double(try repository.getSetting("usage_monitor_used_grams") ?? "") ?? 0
        let residualGramsStored = Double(try repository.getSetting("usage_monitor_residual_grams") ?? "") ?? 0
        let activeSpoolIds = try activeUsageSpoolIds(snapshot)
        let now = ISO8601DateFormatter().string(from: Date())

        if let reconciliation = try reconcileCompletedMulticolorUsage(snapshot) {
            return reconciliation
        }

        if reset || snapshot.signature != lastSignature {
            let message = "Baseline set for \(snapshot.filename)."
            try repository.setSetting("usage_monitor_signature", snapshot.signature)
            try repository.setSetting("usage_monitor_used_grams", String(format: "%.4f", snapshot.usedGrams))
            try repository.setSetting("usage_monitor_residual_grams", "0")
            try repository.setSetting("usage_monitor_last_message", message)
            try repository.setSetting("usage_monitor_last_checked", now)
            try repository.setSetting("usage_monitor_active_spool_ids", activeSpoolIds)
            return UsageApplyResult(tracked: true, baseline: true, message: message)
        }

        let deltaGrams = snapshot.usedGrams - lastUsedGrams
        if deltaGrams <= 0 {
            let message = "No new usage for \(snapshot.filename)."
            try repository.setSetting("usage_monitor_used_grams", String(format: "%.4f", max(snapshot.usedGrams, lastUsedGrams)))
            try repository.setSetting("usage_monitor_last_message", message)
            try repository.setSetting("usage_monitor_last_checked", now)
            try repository.setSetting("usage_monitor_active_spool_ids", activeSpoolIds)
            return UsageApplyResult(tracked: true, message: message)
        }

        let availableGrams = deltaGrams + residualGramsStored
        let wholeGrams = Int(availableGrams)
        let residualGrams = availableGrams - Double(wholeGrams)

        if wholeGrams <= 0 {
            let message = "Accumulating usage for \(snapshot.filename)."
            try repository.setSetting("usage_monitor_used_grams", String(format: "%.4f", snapshot.usedGrams))
            try repository.setSetting("usage_monitor_residual_grams", String(format: "%.4f", residualGrams))
            try repository.setSetting("usage_monitor_last_message", message)
            try repository.setSetting("usage_monitor_last_checked", now)
            try repository.setSetting("usage_monitor_active_spool_ids", activeSpoolIds)
            return UsageApplyResult(tracked: true, message: message, pendingGrams: residualGrams)
        }

        let allocations = try allocateUsageForSnapshot(snapshot, grams: wholeGrams)
        if allocations.isEmpty {
            return try recordPending(snapshot: snapshot, grams: wholeGrams, residualGrams: residualGrams)
        }

        let created = now
        var allocationSummaries: [(spoolId: Int64, label: String, grams: Int)] = []
        for (loaded, grams) in allocations {
            let spool = loaded.spool
            let signatureNote = snapshot.signature.isEmpty ? "" : " Print signature: \(snapshot.signature)."
            let remaining = max(0, spool.remainingWeightG - grams)
            // Deliberately NOT auto-retiring just because the estimate hit
            // zero: gram tracking is an estimate (slicer progress or raw
            // extrusion length), and prematurely retiring drops the spool
            // out of every future matching query -- both here and in
            // syncPrinterSlots -- effectively making the app "forget" a
            // slot that's still physically occupied. Weight clamps at 0;
            // status only changes once the printer itself confirms the
            // spool is gone (syncPrinterSlots's existing removal-detection
            // handles that transition to 'open').
            try repository.updateSpoolAfterUsage(
                spoolId: spool.id,
                remainingWeightG: remaining,
                status: spool.status,
                updatedAtISO: created
            )
            let activeSlotNote = snapshot.activeCFSSlotName.isEmpty ? "" : " Active CFS slot: \(snapshot.activeCFSSlotName)."
            let insertNotes = "Auto printer tracking from \(snapshot.basis) while print state was " +
                "\(snapshot.state.isEmpty ? "unknown" : snapshot.state).\(activeSlotNote)\(signatureNote)"
            try repository.accumulateUsageEvent(
                spoolId: spool.id,
                grams: grams,
                project: snapshot.filename,
                signaturePattern: "%Print signature: \(snapshot.signature)%",
                insertNotes: insertNotes,
                createdISO: created
            )
            allocationSummaries.append((spool.id, "\(spool.brand) \(spool.colorName)", grams))
        }

        let message = "Deducted \(wholeGrams)g from \(allocations.count) loaded spool(s)."
        try repository.setSetting("usage_monitor_signature", snapshot.signature)
        try repository.setSetting("usage_monitor_used_grams", String(format: "%.4f", snapshot.usedGrams))
        try repository.setSetting("usage_monitor_residual_grams", String(format: "%.4f", residualGrams))
        try repository.setSetting("usage_monitor_last_message", message)
        try repository.setSetting("usage_monitor_last_checked", created)
        try repository.setSetting(
            "usage_monitor_active_spool_ids",
            allocationSummaries.map { String($0.spoolId) }.joined(separator: ",")
        )

        return UsageApplyResult(
            tracked: true,
            deducted: wholeGrams,
            message: message,
            pendingGrams: residualGrams,
            allocations: allocationSummaries
        )
    }

    // MARK: - Pending-usage queuing (no spool safely matched to the slot yet)

    private func recordPending(snapshot: PrintUsageSnapshot, grams: Int, residualGrams: Double) throws -> UsageApplyResult {
        let slotName = snapshot.activeCFSSlotName.isEmpty ? "Unknown" : snapshot.activeCFSSlotName.uppercased()
        let created = ISO8601DateFormatter().string(from: Date())
        try repository.recordPendingUsage(
            slotName: slotName,
            signature: snapshot.signature,
            filename: snapshot.filename,
            gramsPending: grams,
            basis: snapshot.basis,
            state: snapshot.state,
            notes: "Queued because no manually loaded spool matched this printer slot.",
            createdISO: created
        )
        let message = "Queued \(grams)g for \(slotName). Load the correct spool in that holder and the app will reconcile it."
        try repository.setSetting("usage_monitor_signature", snapshot.signature)
        try repository.setSetting("usage_monitor_used_grams", String(format: "%.4f", snapshot.usedGrams))
        try repository.setSetting("usage_monitor_residual_grams", String(format: "%.4f", residualGrams))
        try repository.setSetting("usage_monitor_last_message", message)
        try repository.setSetting("usage_monitor_last_checked", created)
        try repository.setSetting("usage_monitor_active_spool_ids", "")
        return UsageApplyResult(
            tracked: true,
            message: message,
            pendingGrams: residualGrams,
            queued: true,
            queuedGrams: grams,
            slotName: slotName
        )
    }

    // MARK: - Completed-print multicolor rebalancing

    /// Mirrors reconcile_completed_multicolor_usage(): once a multicolor
    /// print completes, snap tracked-so-far grams to exactly match the
    /// slicer's planned split (incremental per-poll allocation can drift
    /// slightly while the print is running).
    private func reconcileCompletedMulticolorUsage(_ snapshot: PrintUsageSnapshot) throws -> UsageApplyResult? {
        guard snapshot.state == "completed", snapshot.parts.count >= 2 else { return nil }
        guard !snapshot.signature.isEmpty, !snapshot.filename.isEmpty else { return nil }

        let targets = plannedPartGramTargets(snapshot).sorted(by: >)
        guard targets.count >= 2 else { return nil }

        let signaturePattern = "%Print signature: \(snapshot.signature)%"
        let created = ISO8601DateFormatter().string(from: Date())
        let totals = try repository.usageEventTotals(project: snapshot.filename, signaturePattern: signaturePattern)
        guard totals.count >= 2 else { return nil }

        let observed = Array(totals.prefix(targets.count))
        let assignments = zip(observed, targets).map { (spoolId: $0.spoolId, grams: $1) }
        try repository.rebalanceUsageEvents(
            project: snapshot.filename,
            signaturePattern: signaturePattern,
            targets: assignments,
            createdISO: created
        )

        let message = "Rebalanced completed multicolor print to slicer split (\(targets.map { "\($0)g" }.joined(separator: ",")))."
        try repository.setSetting("usage_monitor_used_grams", String(format: "%.4f", snapshot.usedGrams))
        try repository.setSetting("usage_monitor_residual_grams", "0")
        try repository.setSetting("usage_monitor_last_message", message)
        try repository.setSetting("usage_monitor_last_checked", created)
        try repository.setSetting("usage_monitor_active_spool_ids", "")
        return UsageApplyResult(tracked: true, message: message, rebalanced: true)
    }

    private func plannedPartGramTargets(_ snapshot: PrintUsageSnapshot) -> [Int] {
        let parts = snapshot.parts.filter { $0.plannedGrams > 0 }
        guard !parts.isEmpty else { return [] }
        let targetTotal = max(0, Int(parts.reduce(0) { $0 + $1.plannedGrams }.rounded()))
        var targets: [Int] = []
        var remaining = targetTotal
        for (index, part) in parts.enumerated() {
            let grams = index == parts.count - 1 ? remaining : max(0, Int(part.plannedGrams.rounded()))
            targets.append(grams)
            remaining -= grams
        }
        return targets
    }

    // MARK: - Allocation

    /// Mirrors active_usage_spool_ids(): which spool(s) *would* be drawn
    /// from right now, for UI highlighting — doesn't touch the database.
    private func activeUsageSpoolIds(_ snapshot: PrintUsageSnapshot) throws -> String {
        guard !["completed", "cancelled", "error"].contains(snapshot.state) else { return "" }
        let allocations = try allocateUsageForSnapshot(snapshot, grams: 1)
        return allocations.map { String($0.0.spool.id) }.joined(separator: ",")
    }

    /// Mirrors allocate_usage_for_snapshot(): prefer crediting whichever
    /// spool was already being tracked for a print that just completed,
    /// rather than re-running the live slot-matching heuristic against
    /// whatever happens to be loaded at that moment.
    private func allocateUsageForSnapshot(_ snapshot: PrintUsageSnapshot, grams: Int) throws -> [(SpoolRepository.LoadedCFSSpool, Int)] {
        if snapshot.state == "completed",
           let prior = try priorUsageSpoolForPrint(snapshot),
           prior.remainingWeightG > 0 {
            return [(SpoolRepository.LoadedCFSSpool(spool: prior, locationName: ""), min(grams, max(0, prior.remainingWeightG)))]
        }
        return try allocateUsageToLoadedSpools(snapshot, grams: grams)
    }

    private func priorUsageSpoolForPrint(_ snapshot: PrintUsageSnapshot) throws -> Spool? {
        guard !snapshot.signature.isEmpty, !snapshot.filename.isEmpty else { return nil }
        return try repository.priorUsageSpool(
            filename: snapshot.filename,
            signaturePattern: "%Print signature: \(snapshot.signature)%"
        )
    }

    /// Mirrors allocate_usage_to_loaded_spools(): if the printer tells us
    /// exactly which CFS tray is physically feeding the hotend, trust that
    /// completely. Otherwise, split proportionally across the print's
    /// planned parts by scoring each loaded spool against each part
    /// (material match required, color closeness as a tiebreaker).
    private func allocateUsageToLoadedSpools(_ snapshot: PrintUsageSnapshot, grams: Int) throws -> [(SpoolRepository.LoadedCFSSpool, Int)] {
        guard grams > 0 else { return [] }
        let loadedSpools = try repository.fetchLoadedCFSSpools()
        guard !loadedSpools.isEmpty else { return [] }

        let activeSlotName = snapshot.activeCFSSlotName.uppercased()
        let activeLocationName = UsageSnapshotParser.cfsLocationName(forSlotName: activeSlotName) ?? ""
        if !activeSlotName.isEmpty || !activeLocationName.isEmpty {
            for loaded in loadedSpools {
                let slotMatches = (loaded.spool.cfsSlotName?.uppercased() ?? "") == activeSlotName
                let locationMatches = loaded.locationName == activeLocationName
                if (slotMatches || locationMatches) && loaded.spool.remainingWeightG > 0 {
                    return [(loaded, min(grams, max(0, loaded.spool.remainingWeightG)))]
                }
            }
            return []
        }

        // The printer only reports an "actively feeding" signal for the
        // four CFS box trays -- there's no equivalent for the External
        // Spool Holder, so printing from External always lands here with
        // no active-slot info at all. When there's genuinely only one
        // candidate loaded anywhere, there's no ambiguity to resolve by
        // scoring: it has to be the one being drawn from, regardless of
        // what its stored material/color happen to say. This is the same
        // confidence level as the active-slot match above, just inferred
        // from "nothing else it could be" instead of a printer signal.
        if loadedSpools.count == 1, let only = loadedSpools.first, only.spool.remainingWeightG > 0 {
            return [(only, min(grams, max(0, only.spool.remainingWeightG)))]
        }

        let parts = snapshot.parts
        let totalPartGrams = parts.reduce(0) { $0 + $1.plannedGrams }
        let totalForRatio = totalPartGrams > 0 ? totalPartGrams : 1.0
        var usedIds: Set<Int64> = []
        var allocationsById: [Int64: (SpoolRepository.LoadedCFSSpool, Int)] = [:]
        var remaining = grams
        for (index, part) in parts.enumerated() {
            guard let spool = chooseSpoolForPart(part, loadedSpools: loadedSpools, usedIds: usedIds) else { continue }
            usedIds.insert(spool.spool.id)
            let partGrams: Int
            if index == parts.count - 1 {
                partGrams = remaining
            } else {
                partGrams = max(0, Int((Double(grams) * (part.plannedGrams / totalForRatio)).rounded()))
            }
            remaining -= partGrams
            let existing = allocationsById[spool.spool.id] ?? (spool, 0)
            allocationsById[spool.spool.id] = (existing.0, existing.1 + partGrams)
        }
        return allocationsById.values
            .filter { $0.1 > 0 && $0.0.spool.remainingWeightG > 0 }
            .map { ($0.0, min($0.1, max(0, $0.0.spool.remainingWeightG))) }
    }

    /// Mirrors choose_spool_for_part(): score every loaded spool against
    /// this part by material match (required) and color closeness
    /// (tiebreaker), penalizing spools already claimed by an earlier part
    /// in the same allocation pass.
    private func chooseSpoolForPart(
        _ part: UsagePart,
        loadedSpools: [SpoolRepository.LoadedCFSSpool],
        usedIds: Set<Int64>
    ) -> SpoolRepository.LoadedCFSSpool? {
        var candidates: [(score: Int, spool: SpoolRepository.LoadedCFSSpool)] = []
        var materialCandidates: [SpoolRepository.LoadedCFSSpool] = []
        let partMaterial = UsageMath.normalizeMaterialLabel(part.material)

        for loaded in loadedSpools {
            let spoolMaterial = UsageMath.normalizeMaterialLabel(loaded.spool.material)
            guard UsageMath.materialMatches(partMaterial, spoolMaterial) else { continue }

            var score = 100
            if partMaterial == spoolMaterial { score += 40 }
            materialCandidates.append(loaded)

            if !part.colorHex.isEmpty {
                let distance = UsageMath.colorDistance(part.colorHex, loaded.spool.colorHex)
                if distance <= 120 {
                    score += max(0, 180 - distance)
                } else {
                    score -= min(140, distance / 3)
                }
            }
            if usedIds.contains(loaded.spool.id) { score -= 50 }
            if score > 0 { candidates.append((score, loaded)) }
        }

        if candidates.isEmpty {
            let available = materialCandidates.filter { !usedIds.contains($0.spool.id) && $0.spool.remainingWeightG > 0 }
            return available.count == 1 ? available[0] : nil
        }
        candidates.sort { $0.score > $1.score }
        return candidates[0].spool
    }
}
