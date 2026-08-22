//
//  SpoolRepository.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Typed read/write helpers on top of FilamentDatabase. This is the layer
//  the UI and (later) printer-sync code talk to, so nothing above this
//  needs to know SQL.
//

import Foundation
import SQLite3

final class SpoolRepository {
    private let db: FilamentDatabase

    init(db: FilamentDatabase) {
        self.db = db
    }

    // MARK: - Locations

    func fetchLocations() throws -> [Location] {
        var results: [Location] = []
        try db.query("SELECT id, name, kind, sort_order FROM locations ORDER BY sort_order, name") { stmt in
            guard
                let name = stmt.stringColumn(1),
                let kindRaw = stmt.stringColumn(2),
                let kind = Location.Kind(rawValue: kindRaw)
            else { return }
            results.append(
                Location(
                    id: Int64(stmt.intColumn(0)),
                    name: name,
                    kind: kind,
                    sortOrder: stmt.intColumn(3)
                )
            )
        }
        return results
    }

    // MARK: - Spools

    private static let spoolColumns = """
        id, barcode, material, brand, color_name, color_hex, diameter,
        original_weight_g, remaining_weight_g, status, location_id,
        cfs_slot_name, purchased_at, opened_at, notes, created_at, updated_at,
        creality_filament_id, creality_brand, creality_type, creality_name,
        cfs_material_code, cfs_color_code
        """

    private func spool(from stmt: OpaquePointer) -> Spool? {
        guard
            let material = stmt.stringColumn(2),
            let brand = stmt.stringColumn(3),
            let colorName = stmt.stringColumn(4),
            let colorHex = stmt.stringColumn(5),
            let diameter = stmt.stringColumn(6),
            let statusRaw = stmt.stringColumn(9),
            let status = Spool.Status(rawValue: statusRaw),
            let notes = stmt.stringColumn(14),
            let createdAt = stmt.stringColumn(15),
            let updatedAt = stmt.stringColumn(16)
        else { return nil }

        return Spool(
            id: Int64(stmt.intColumn(0)),
            barcode: stmt.stringColumn(1),
            material: material,
            brand: brand,
            colorName: colorName,
            colorHex: colorHex,
            diameter: diameter,
            originalWeightG: stmt.intColumn(7),
            remainingWeightG: stmt.intColumn(8),
            status: status,
            locationId: stmt.optionalIntColumn(10),
            cfsSlotName: stmt.stringColumn(11),
            purchasedAt: stmt.stringColumn(12),
            openedAt: stmt.stringColumn(13),
            notes: notes,
            createdAt: createdAt,
            updatedAt: updatedAt,
            crealityFilamentId: stmt.optionalIntColumn(17),
            crealityBrand: stmt.stringColumn(18),
            crealityType: stmt.stringColumn(19),
            crealityName: stmt.stringColumn(20),
            cfsMaterialCode: stmt.stringColumn(21),
            cfsColorCode: stmt.stringColumn(22)
        )
    }

    func fetchAllSpools() throws -> [Spool] {
        var results: [Spool] = []
        try db.query(
            "SELECT \(Self.spoolColumns) FROM spools ORDER BY status, brand, material, color_name"
        ) { stmt in
            if let spool = self.spool(from: stmt) {
                results.append(spool)
            }
        }
        return results
    }

    func fetchSpool(id: Int64) throws -> Spool? {
        var found: Spool?
        try db.query(
            "SELECT \(Self.spoolColumns) FROM spools WHERE id = ?",
            bind: [id]
        ) { stmt in
            found = self.spool(from: stmt)
        }
        return found
    }

    func updateRemainingWeight(spoolId: Int64, remainingGrams: Int, nowISO: String) throws {
        try db.run(
            "UPDATE spools SET remaining_weight_g = ?, updated_at = ? WHERE id = ?",
            bind: [remainingGrams, nowISO, spoolId]
        )
    }

    // MARK: - Settings

    func fetchSettings() throws -> [String: String] {
        var results: [String: String] = [:]
        try db.query("SELECT key, value FROM settings") { stmt in
            guard let key = stmt.stringColumn(0), let value = stmt.stringColumn(1) else { return }
            results[key] = value
        }
        return results
    }

    func setSetting(_ key: String, _ value: String) throws {
        try db.run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bind: [key, value]
        )
    }

    // MARK: - Creality filament catalog

    func crealityFilamentCount() throws -> Int {
        var count = 0
        try db.query("SELECT COUNT(*) FROM creality_filaments") { stmt in
            count = stmt.intColumn(0)
        }
        return count
    }

    // MARK: - Printer sync

    func fetchLoadedSpool(atLocationId locationId: Int64) throws -> Spool? {
        var found: Spool?
        try db.query(
            "SELECT \(Self.spoolColumns) FROM spools WHERE location_id = ? AND status = 'loaded' LIMIT 1",
            bind: [locationId]
        ) { stmt in
            found = self.spool(from: stmt)
        }
        return found
    }

    private func markSpoolLoaded(spoolId: Int64, locationId: Int64, cfsSlotName: String, nowISO: String) throws {
        try db.run(
            "UPDATE spools SET status = 'loaded', location_id = ?, cfs_slot_name = ?, updated_at = ? WHERE id = ?",
            bind: [locationId, cfsSlotName, nowISO, spoolId]
        )
    }

    private func clearLoadedSpools(exceptLocationIds keepIds: Set<Int64>, movingTo dehumidifierId: Int64, nowISO: String) throws {
        var sql = """
            UPDATE spools
            SET status = 'open', location_id = ?, cfs_slot_name = NULL, updated_at = ?
            WHERE status = 'loaded'
              AND location_id IN (
                SELECT id FROM locations
                WHERE (kind = 'cfs' AND name LIKE 'CFS Slot %') OR name = 'External Spool Holder'
              )
            """
        var binds: [SQLiteBindable] = [dehumidifierId, nowISO]
        if !keepIds.isEmpty {
            let placeholders = keepIds.map { _ in "?" }.joined(separator: ",")
            sql += " AND location_id NOT IN (\(placeholders))"
            binds.append(contentsOf: keepIds.map { $0 as SQLiteBindable })
        }
        try db.run(sql, bind: binds)
    }

    /// Matches printer-reported CFS/external-holder contents to existing
    /// spools by location. Mirrors upsert_synced_slots() from the original
    /// Python app: it only ever updates the *status/location* of spools you
    /// already told it about — it never invents a new spool for a slot it
    /// doesn't recognize, since the printer's RFID/material-code data isn't
    /// trustworthy enough on its own to create inventory records from.
    @discardableResult
    func syncPrinterSlots(cfsSlots: [ParsedCFSSlot], externalSlot: ParsedCFSSlot?) throws -> String {
        let locations = try fetchLocations()
        let cfsLocations = locations
            .filter { $0.kind == .cfs && $0.name.hasPrefix("CFS Slot") }
            .sorted { $0.sortOrder < $1.sortOrder }
        let externalLocation = locations.first { $0.name == "External Spool Holder" }
        let dehumidifier = locations.first { $0.kind == .dryer }

        var seenLocationIds: Set<Int64> = []
        var unmatchedSlotNames: [String] = []
        // New: unlike the old app, which never compared printer-reported
        // identity against a spool already on file once it trusted that
        // spool, this flags disagreement without ever acting on it -- the
        // database still always wins, this just tells you when it might
        // be wrong so you can go check.
        var conflictNotes: [String] = []
        let now = ISO8601DateFormatter().string(from: Date())

        func sync(_ slot: ParsedCFSSlot, locationId: Int64) throws {
            seenLocationIds.insert(locationId)
            if let existing = try fetchLoadedSpool(atLocationId: locationId) {
                try markSpoolLoaded(spoolId: existing.id, locationId: locationId, cfsSlotName: slot.slotName, nowISO: now)
                // Mirrors reconcile_pending_usage_for_spool() being called
                // right after a spool is assigned into a CFS holder: credit
                // any usage that queued up while no spool was safely
                // matched to this slot. Safe to call on every sync poll —
                // it's a no-op once there's nothing pending for the slot.
                try reconcilePendingUsage(forSpoolId: existing.id, slotName: slot.slotName)
                if let conflict = conflictDescription(slot: slot, existing: existing) {
                    conflictNotes.append(conflict)
                }
            } else {
                unmatchedSlotNames.append(slot.slotName)
            }
        }

        for slot in cfsSlots {
            guard let index = slot.slotIndex, index < cfsLocations.count else { continue }
            try sync(slot, locationId: cfsLocations[index].id)
        }
        if let externalSlot, let externalLocation {
            try sync(externalSlot, locationId: externalLocation.id)
        }

        if !seenLocationIds.isEmpty, unmatchedSlotNames.isEmpty, let dehumidifierId = dehumidifier?.id {
            try clearLoadedSpools(exceptLocationIds: seenLocationIds, movingTo: dehumidifierId, nowISO: now)
        }

        let message: String
        if !unmatchedSlotNames.isEmpty {
            message = "Printer sync found unmatched slot(s): \(unmatchedSlotNames.joined(separator: ", ")). No spools were auto-created."
        } else if !conflictNotes.isEmpty {
            message = "Printer sync found possible mismatch(es): \(conflictNotes.joined(separator: " "))"
        } else if seenLocationIds.isEmpty {
            message = "Printer connected; nothing currently loaded."
        } else {
            message = "Synced \(seenLocationIds.count) slot(s) at \(now)."
        }
        try setSetting("slot_sync_last_message", message)
        try setSetting("slot_sync_last_checked", now)
        return message
    }

    /// Compares the printer's reported material/color code for a slot
    /// against the spool already on file there. Purely informational —
    /// never changes any data, since we deliberately never let printer
    /// RFID/material data override the manually-loaded spool the user put
    /// there. Only flags when both sides actually have a code to compare
    /// (missing/blank codes on either side are common and not a mismatch).
    private func conflictDescription(slot: ParsedCFSSlot, existing: Spool) -> String? {
        let printerMaterial = slot.cfsMaterialCode.trimmingCharacters(in: .whitespaces)
        let printerColor = slot.cfsColorCode.trimmingCharacters(in: .whitespaces)
        let spoolMaterial = (existing.cfsMaterialCode ?? "").trimmingCharacters(in: .whitespaces)
        let spoolColor = (existing.cfsColorCode ?? "").trimmingCharacters(in: .whitespaces)

        let materialMismatch = !printerMaterial.isEmpty && !spoolMaterial.isEmpty
            && printerMaterial.caseInsensitiveCompare(spoolMaterial) != .orderedSame
        let colorMismatch = !printerColor.isEmpty && !spoolColor.isEmpty
            && printerColor.caseInsensitiveCompare(spoolColor) != .orderedSame
        guard materialMismatch || colorMismatch else { return nil }

        let printerDescription = [slot.material, slot.colorName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let spoolDescription = "\(existing.brand) \(existing.colorName)"
        return "\(slot.slotName): printer reports " +
            "\(printerDescription.isEmpty ? "different filament" : printerDescription), " +
            "inventory has \(spoolDescription) — verify what's physically loaded."
    }

    // MARK: - Usage tracking

    func getSetting(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM settings WHERE key = ? LIMIT 1", bind: [key]) { stmt in
            value = stmt.stringColumn(0)
        }
        return value
    }

    struct LoadedCFSSpool {
        var spool: Spool
        var locationName: String
    }

    /// Spools currently loaded into a CFS-kind location — the pool of
    /// candidates usage gets allocated against.
    func fetchLoadedCFSSpools() throws -> [LoadedCFSSpool] {
        var results: [LoadedCFSSpool] = []
        try db.query("""
            SELECT \(Self.spoolColumns.split(separator: ",").map { "s.\($0.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: ", ")), l.name
            FROM spools s
            JOIN locations l ON l.id = s.location_id
            WHERE s.status = 'loaded' AND l.kind = 'cfs'
            ORDER BY l.sort_order, s.id
            """
        ) { stmt in
            guard let spool = self.spool(from: stmt), let locationName = stmt.stringColumn(23) else { return }
            results.append(LoadedCFSSpool(spool: spool, locationName: locationName))
        }
        return results
    }

    /// Mirrors prior_usage_spool_for_print(): when a print has *completed*,
    /// prefer crediting the spool that was already being tracked for it
    /// over re-running the live allocation heuristic.
    func priorUsageSpool(filename: String, signaturePattern: String) throws -> Spool? {
        var found: Spool?
        try db.query("""
            SELECT \(Self.spoolColumns.split(separator: ",").map { "s.\($0.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: ", "))
            FROM usage_events u
            JOIN spools s ON s.id = u.spool_id
            WHERE u.project = ?
              AND u.notes LIKE 'Auto printer tracking%'
              AND u.notes LIKE ?
              AND s.status = 'loaded'
            GROUP BY s.id
            ORDER BY SUM(u.grams_used) DESC, MAX(u.id) DESC
            LIMIT 1
            """,
            bind: [filename, signaturePattern]
        ) { stmt in
            found = self.spool(from: stmt)
        }
        return found
    }

    /// Adds `grams` to the most recent matching "Auto printer tracking"
    /// usage_events row for this spool+print, or inserts a new one if none
    /// exists yet. Mirrors the UPDATE-then-INSERT-if-no-match pattern in
    /// apply_printer_usage_snapshot().
    func accumulateUsageEvent(
        spoolId: Int64,
        grams: Int,
        project: String,
        signaturePattern: String,
        insertNotes: String,
        createdISO: String
    ) throws {
        try db.run(
            """
            UPDATE usage_events
            SET grams_used = grams_used + ?, created_at = ?
            WHERE id = (
                SELECT id FROM usage_events
                WHERE spool_id = ? AND project = ?
                  AND notes LIKE 'Auto printer tracking%' AND notes LIKE ?
                ORDER BY id DESC LIMIT 1
            )
            """,
            bind: [grams, createdISO, spoolId, project, signaturePattern]
        )
        if db.lastChangeCount == 0 {
            try db.run(
                "INSERT INTO usage_events (spool_id, grams_used, project, notes, created_at) VALUES (?, ?, ?, ?, ?)",
                bind: [spoolId, grams, project, insertNotes, createdISO]
            )
        }
    }

    func updateSpoolAfterUsage(spoolId: Int64, remainingWeightG: Int, status: Spool.Status, updatedAtISO: String) throws {
        try db.run(
            "UPDATE spools SET remaining_weight_g = ?, status = ?, updated_at = ? WHERE id = ?",
            bind: [remainingWeightG, status.rawValue, updatedAtISO, spoolId]
        )
    }

    func recordPendingUsage(
        slotName: String,
        signature: String,
        filename: String,
        gramsPending: Int,
        basis: String,
        state: String,
        notes: String,
        createdISO: String
    ) throws {
        try db.run(
            """
            INSERT INTO pending_usage_events (
                slot_name, signature, filename, grams_pending, basis, state, notes, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(slot_name, signature) DO UPDATE SET
                grams_pending = grams_pending + excluded.grams_pending,
                filename = excluded.filename,
                basis = excluded.basis,
                state = excluded.state,
                notes = excluded.notes,
                updated_at = excluded.updated_at
            """,
            bind: [slotName, signature, filename, gramsPending, basis, state, notes, createdISO, createdISO]
        )
    }

    /// Mirrors reconcile_pending_usage_for_spool(): when a spool becomes
    /// loaded in a CFS holder, credit it for any usage that was queued
    /// against that holder while no spool was safely identified there.
    @discardableResult
    func reconcilePendingUsage(forSpoolId spoolId: Int64, slotName: String) throws -> Int {
        guard let spool = try fetchSpool(id: spoolId), spool.status == .loaded else { return 0 }

        var pending: [(id: Int64, grams: Int)] = []
        try db.query(
            "SELECT id, grams_pending FROM pending_usage_events WHERE slot_name = ? AND grams_pending > 0 ORDER BY created_at, id",
            bind: [slotName]
        ) { stmt in
            pending.append((id: Int64(stmt.intColumn(0)), grams: stmt.intColumn(1)))
        }
        let totalGrams = pending.reduce(0) { $0 + $1.grams }
        guard totalGrams > 0 else { return 0 }

        let createdISO = ISO8601DateFormatter().string(from: Date())
        let newRemaining = max(0, spool.remainingWeightG - totalGrams)
        // Don't auto-retire on hitting zero -- see the matching note in
        // UsageTrackingEngine.apply(). `spool.status` is already `.loaded`
        // here (guarded above), so this just preserves it explicitly.
        try updateSpoolAfterUsage(
            spoolId: spoolId,
            remainingWeightG: newRemaining,
            status: spool.status,
            updatedAtISO: createdISO
        )
        for row in pending {
            let notes = "Reconciled pending printer usage after manual load. Active holder: \(slotName)."
            try db.run(
                "INSERT INTO usage_events (spool_id, grams_used, project, notes, created_at) VALUES (?, ?, '', ?, ?)",
                bind: [spoolId, row.grams, notes, createdISO]
            )
        }
        try db.run("DELETE FROM pending_usage_events WHERE slot_name = ?", bind: [slotName])
        try setSetting("usage_monitor_last_message", "Reconciled \(totalGrams)g of queued printer usage to \(spool.brand) \(spool.colorName).")
        try setSetting("usage_monitor_last_checked", createdISO)
        return totalGrams
    }

    /// Mirrors reconcile_completed_multicolor_usage(): once a multicolor
    /// print completes, snap the tracked-so-far grams for each involved
    /// spool to exactly match the slicer's planned split (incremental
    /// per-poll allocation can drift slightly during the print).
    func rebalanceUsageEvents(
        project: String,
        signaturePattern: String,
        targets: [(spoolId: Int64, grams: Int)],
        createdISO: String
    ) throws {
        for target in targets {
            var currentEventId: Int64?
            var currentGrams = 0
            try db.query(
                """
                SELECT id, grams_used FROM usage_events
                WHERE spool_id = ? AND project = ?
                  AND notes LIKE 'Auto printer tracking%' AND notes LIKE ?
                ORDER BY id DESC LIMIT 1
                """,
                bind: [target.spoolId, project, signaturePattern]
            ) { stmt in
                currentEventId = Int64(stmt.intColumn(0))
                currentGrams = stmt.intColumn(1)
            }

            let delta = target.grams - currentGrams
            if delta != 0, let spool = try fetchSpool(id: target.spoolId) {
                let newRemaining = max(0, spool.remainingWeightG - delta)
                // Don't auto-retire on hitting zero -- see the matching
                // note in UsageTrackingEngine.apply(); preserve whatever
                // status the spool already has.
                try updateSpoolAfterUsage(
                    spoolId: target.spoolId,
                    remainingWeightG: newRemaining,
                    status: spool.status,
                    updatedAtISO: createdISO
                )
            }
            if let eventId = currentEventId {
                try db.run(
                    """
                    UPDATE usage_events
                    SET grams_used = ?, created_at = ?,
                        notes = CASE WHEN notes LIKE '%Rebalanced to completed slicer split.%' THEN notes
                                     ELSE notes || ' Rebalanced to completed slicer split.' END
                    WHERE id = ?
                    """,
                    bind: [target.grams, createdISO, eventId]
                )
            }
        }
    }

    /// Grouped totals of "Auto printer tracking" grams recorded so far for
    /// this print, ordered highest-first — used to line up against the
    /// slicer's planned per-part targets during rebalancing.
    func usageEventTotals(project: String, signaturePattern: String) throws -> [(spoolId: Int64, gramsUsed: Int)] {
        var results: [(spoolId: Int64, gramsUsed: Int)] = []
        try db.query(
            """
            SELECT spool_id, SUM(grams_used) AS total
            FROM usage_events
            WHERE project = ? AND notes LIKE 'Auto printer tracking%' AND notes LIKE ?
            GROUP BY spool_id
            ORDER BY total DESC, spool_id
            """,
            bind: [project, signaturePattern]
        ) { stmt in
            results.append((spoolId: Int64(stmt.intColumn(0)), gramsUsed: stmt.intColumn(1)))
        }
        return results
    }
}
