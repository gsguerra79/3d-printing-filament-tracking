//
//  SpoolEditing.swift
//  Creality K2 Filament Tracker and Inventory
//
//  CRUD and catalog-lookup methods backing the Add/Edit/Load/Log-Usage UI —
//  everything the old app's manual editing endpoints
//  (POST/PUT/DELETE /api/spools, POST /api/spools/<id>/usage,
//  GET /api/catalog/options) did, ported to direct SQLite calls. Kept in its
//  own file since SpoolRepository.swift is already large and this is a
//  distinct concern (user-driven editing vs. printer-driven sync).
//

import Foundation
import SQLite3

extension SpoolRepository {
    // MARK: - Catalog lookups (for the spool editor's cascading pickers)

    func catalogBrands() throws -> [String] {
        var results: [String] = []
        try db.query(
            """
            SELECT DISTINCT brand FROM creality_filaments
            ORDER BY CASE brand WHEN 'Creality' THEN 0 WHEN 'Generic' THEN 1 ELSE 2 END, brand
            """
        ) { stmt in
            if let brand = stmt.stringColumn(0) { results.append(brand) }
        }
        return results
    }

    func catalogTypes(forBrand brand: String) throws -> [String] {
        var results: [String] = []
        let orderClause = "ORDER BY CASE type WHEN 'PLA' THEN 0 WHEN 'PETG' THEN 1 WHEN 'TPU' THEN 2 WHEN 'ABS' THEN 3 ELSE 4 END, type"
        if brand.isEmpty {
            try db.query("SELECT DISTINCT type FROM creality_filaments \(orderClause)") { stmt in
                if let type = stmt.stringColumn(0) { results.append(type) }
            }
        } else {
            try db.query(
                "SELECT DISTINCT type FROM creality_filaments WHERE brand = ? \(orderClause)",
                bind: [brand]
            ) { stmt in
                if let type = stmt.stringColumn(0) { results.append(type) }
            }
        }
        return results
    }

    func catalogNames(forBrand brand: String, type: String) throws -> [CatalogNameOption] {
        var clauses: [String] = []
        var binds: [SQLiteBindable] = []
        if !brand.isEmpty { clauses.append("brand = ?"); binds.append(brand) }
        if !type.isEmpty { clauses.append("type = ?"); binds.append(type) }
        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"

        var results: [CatalogNameOption] = []
        var seen: Set<String> = []
        try db.query(
            """
            SELECT id, brand, type, name FROM creality_filaments
            \(whereClause)
            ORDER BY
              CASE WHEN cfs_material_code IS NOT NULL THEN 0 ELSE 1 END,
              CASE WHEN LOWER(name) = LOWER(type) THEN 0 ELSE 1 END,
              name
            LIMIT 500
            """,
            bind: binds
        ) { stmt in
            guard
                let rowBrand = stmt.stringColumn(1),
                let rowType = stmt.stringColumn(2),
                let name = stmt.stringColumn(3)
            else { return }
            let key = "\(rowBrand)|\(rowType)|\(name)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            results.append(CatalogNameOption(id: Int64(stmt.intColumn(0)), name: name))
        }
        return results
    }

    /// Looks up the canonical brand/type/name/cfs_material_code for a
    /// specific catalog row. The spool editor always saves a concrete
    /// `crealityFilamentId` (from its own cascading pickers), and this is
    /// how that id gets turned into the values actually stored on the
    /// spool — mirrors apply_creality_mapping() trusting the matched
    /// catalog row over whatever the client happened to send.
    private func resolvedCrealityFields(
        forFilamentId filamentId: Int64?
    ) throws -> (id: Int64, brand: String, type: String, name: String, cfsMaterialCode: String?)? {
        guard let filamentId else { return nil }
        var result: (id: Int64, brand: String, type: String, name: String, cfsMaterialCode: String?)?
        try db.query(
            "SELECT id, brand, type, name, cfs_material_code FROM creality_filaments WHERE id = ? LIMIT 1",
            bind: [filamentId]
        ) { stmt in
            result = (
                id: Int64(stmt.intColumn(0)),
                brand: stmt.stringColumn(1) ?? "",
                type: stmt.stringColumn(2) ?? "",
                name: stmt.stringColumn(3) ?? "",
                cfsMaterialCode: stmt.stringColumn(4)
            )
        }
        return result
    }

    // MARK: - Recent usage feed

    func fetchRecentUsageEvents(limit: Int = 50) throws -> [UsageEventDisplay] {
        var results: [UsageEventDisplay] = []
        try db.query(
            """
            SELECT u.id, u.spool_id, u.grams_used, u.project, u.notes, u.created_at,
                   s.material, s.brand, s.color_name, s.color_hex
            FROM usage_events u
            JOIN spools s ON s.id = u.spool_id
            ORDER BY u.created_at DESC, u.id DESC
            LIMIT ?
            """,
            bind: [limit]
        ) { stmt in
            guard
                let project = stmt.stringColumn(3),
                let notes = stmt.stringColumn(4),
                let createdAt = stmt.stringColumn(5),
                let material = stmt.stringColumn(6),
                let brand = stmt.stringColumn(7),
                let colorName = stmt.stringColumn(8),
                let colorHex = stmt.stringColumn(9)
            else { return }
            results.append(UsageEventDisplay(
                id: Int64(stmt.intColumn(0)),
                spoolId: Int64(stmt.intColumn(1)),
                gramsUsed: stmt.intColumn(2),
                project: project,
                notes: notes,
                createdAt: createdAt,
                material: material,
                brand: brand,
                colorName: colorName,
                colorHex: colorHex
            ))
        }
        return results
    }

    // MARK: - Create / update / delete

    /// Locations tagged `.cfs` cover both "CFS Slot N" and "External Spool
    /// Holder" (see DefaultLocations) — selecting one of these as a spool's
    /// location always means the spool is loaded.
    private func normalizedStatus(_ status: Spool.Status, locationId: Int64?, locations: [Location]) -> Spool.Status {
        if let locationId, locations.first(where: { $0.id == locationId })?.kind == .cfs {
            return .loaded
        } else if status == .loaded {
            return .open
        }
        return status
    }

    @discardableResult
    func createSpool(_ draft: SpoolDraft) throws -> Int64 {
        let locations = try fetchLocations()
        let now = ISO8601DateFormatter().string(from: Date())
        let today = String(now.prefix(10))
        let status = normalizedStatus(draft.status, locationId: draft.locationId, locations: locations)
        var openedAt = draft.openedAt
        if (status == .open || status == .loaded), openedAt.isEmpty { openedAt = today }

        let resolved = try resolvedCrealityFields(forFilamentId: draft.crealityFilamentId)
        let finalBrand = draft.crealityBrand.caseInsensitiveCompare("Generic") == .orderedSame ? draft.brand : draft.crealityBrand
        let finalMaterial = (resolved?.type ?? draft.material).uppercased()
        let slotName: String? = status == .loaded
            ? draft.locationId.flatMap { id in locations.first(where: { $0.id == id }) }.flatMap { Self.cfsSlotName(forLocationName: $0.name) }
            : nil

        try db.run(
            """
            INSERT INTO spools (
                barcode, material, brand, color_name, color_hex, diameter,
                original_weight_g, remaining_weight_g, status, location_id,
                cfs_slot_name, purchased_at, opened_at, notes, creality_filament_id,
                creality_brand, creality_type, creality_name, cfs_material_code,
                cfs_color_code, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                draft.barcode.isEmpty ? String?.none : draft.barcode,
                finalMaterial,
                finalBrand,
                draft.colorName,
                draft.colorHex,
                draft.diameter,
                draft.originalWeightG,
                min(draft.remainingWeightG, draft.originalWeightG),
                status.rawValue,
                draft.locationId,
                slotName,
                draft.purchasedAt.isEmpty ? String?.none : draft.purchasedAt,
                openedAt.isEmpty ? String?.none : openedAt,
                draft.notes,
                resolved?.id,
                resolved?.brand ?? (draft.crealityBrand.isEmpty ? String?.none : draft.crealityBrand),
                resolved?.type ?? (draft.crealityType.isEmpty ? String?.none : draft.crealityType),
                resolved?.name ?? (draft.crealityName.isEmpty ? String?.none : draft.crealityName),
                resolved?.cfsMaterialCode,
                String?.none,
                now,
                now,
            ]
        )
        let newId = db.lastInsertRowId
        try enforceSingleLoadedSpool(locationId: draft.locationId, loadedSpoolId: newId)
        try reconcilePendingUsage(forSpoolId: newId, slotName: slotName ?? "")
        return newId
    }

    func updateSpool(id: Int64, draft: SpoolDraft) throws {
        guard let existing = try fetchSpool(id: id) else { return }
        let locations = try fetchLocations()
        let now = ISO8601DateFormatter().string(from: Date())
        let today = String(now.prefix(10))
        let status = normalizedStatus(draft.status, locationId: draft.locationId, locations: locations)
        var openedAt = draft.openedAt.isEmpty ? (existing.openedAt ?? "") : draft.openedAt
        if (status == .open || status == .loaded), openedAt.isEmpty { openedAt = today }

        let resolved = try resolvedCrealityFields(forFilamentId: draft.crealityFilamentId)
        let finalBrand = draft.crealityBrand.caseInsensitiveCompare("Generic") == .orderedSame ? draft.brand : draft.crealityBrand
        let finalMaterial = (resolved?.type ?? draft.material).uppercased()
        let slotName: String? = status == .loaded
            ? draft.locationId.flatMap { id in locations.first(where: { $0.id == id }) }.flatMap { Self.cfsSlotName(forLocationName: $0.name) }
            : nil

        // Deliberately does NOT touch cfs_material_code/cfs_color_code —
        // those are populated by printer sync (matching RFID/CFS reads
        // against the loaded slot), not by the manual editor, and editing a
        // spool's brand/color here shouldn't erase a printer-confirmed code.
        try db.run(
            """
            UPDATE spools
            SET barcode = ?, material = ?, brand = ?, color_name = ?, color_hex = ?,
                diameter = ?, original_weight_g = ?, remaining_weight_g = ?,
                status = ?, location_id = ?, purchased_at = ?, opened_at = ?,
                notes = ?, creality_filament_id = ?, creality_brand = ?,
                creality_type = ?, creality_name = ?, cfs_slot_name = ?, updated_at = ?
            WHERE id = ?
            """,
            bind: [
                draft.barcode.isEmpty ? String?.none : draft.barcode,
                finalMaterial,
                finalBrand,
                draft.colorName,
                draft.colorHex,
                draft.diameter,
                draft.originalWeightG,
                min(draft.remainingWeightG, draft.originalWeightG),
                status.rawValue,
                draft.locationId,
                draft.purchasedAt.isEmpty ? String?.none : draft.purchasedAt,
                openedAt.isEmpty ? String?.none : openedAt,
                draft.notes,
                resolved?.id,
                resolved?.brand ?? (draft.crealityBrand.isEmpty ? String?.none : draft.crealityBrand),
                resolved?.type ?? (draft.crealityType.isEmpty ? String?.none : draft.crealityType),
                resolved?.name ?? (draft.crealityName.isEmpty ? String?.none : draft.crealityName),
                slotName,
                now,
                id,
            ]
        )
        try enforceSingleLoadedSpool(locationId: draft.locationId, loadedSpoolId: id)
        try reconcilePendingUsage(forSpoolId: id, slotName: slotName ?? "")
    }

    func deleteSpool(id: Int64) throws {
        try db.run("DELETE FROM spools WHERE id = ?", bind: [id])
    }

    // MARK: - Card actions: retire / load / log usage

    /// Retires a spool in place (keeping its current remaining weight) —
    /// the manual "Retire" card action. Goes through updateSpoolAfterUsage
    /// so it also moves to the Retired/Empty location, same as an
    /// automatic zero-weight retirement would.
    func retireSpool(id: Int64) throws {
        guard let spool = try fetchSpool(id: id) else { return }
        try updateSpoolAfterUsage(
            spoolId: id,
            remainingWeightG: spool.remainingWeightG,
            status: .retired,
            updatedAtISO: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Manually loads an existing spool into a CFS slot / the external
    /// holder — the "Load" card action. Swaps out whatever spool was
    /// already loaded there (moved to Dehumidifier/open, same as
    /// enforce_single_loaded_spool in the old app) rather than leaving two
    /// spools marked loaded at the same physical location.
    func loadSpool(id: Int64, locationId: Int64) throws {
        guard let location = try fetchLocations().first(where: { $0.id == locationId }) else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let today = String(now.prefix(10))
        let slotName = Self.cfsSlotName(forLocationName: location.name)
        try db.run(
            """
            UPDATE spools
            SET status = 'loaded', location_id = ?, cfs_slot_name = ?,
                opened_at = COALESCE(opened_at, ?), updated_at = ?
            WHERE id = ?
            """,
            bind: [locationId, slotName, today, now, id]
        )
        try enforceSingleLoadedSpool(locationId: locationId, loadedSpoolId: id)
        try reconcilePendingUsage(forSpoolId: id, slotName: slotName ?? "")
    }

    /// Manually logs a chunk of usage against a spool — the "Log Usage"
    /// dialog. Distinct from the automatic printer-usage-tracking path in
    /// UsageTrackingEngine: this is a deliberate one-shot entry the user
    /// typed in themselves, so (matching the old app) it's allowed to
    /// retire the spool outright if it zeroes out, rather than waiting for
    /// the printer to confirm removal.
    func logUsage(spoolId: Int64, grams: Int, project: String, notes: String) throws {
        guard let spool = try fetchSpool(id: spoolId) else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let remaining = max(0, spool.remainingWeightG - grams)
        let status: Spool.Status = remaining == 0 ? .retired : spool.status
        try updateSpoolAfterUsage(spoolId: spoolId, remainingWeightG: remaining, status: status, updatedAtISO: now)
        try db.run(
            "INSERT INTO usage_events (spool_id, grams_used, project, notes, created_at) VALUES (?, ?, ?, ?, ?)",
            bind: [spoolId, grams, project, notes, now]
        )
    }

    /// Mirrors enforce_single_loaded_spool(): loading a spool into a CFS
    /// slot bumps out whatever spool was already marked loaded there.
    private func enforceSingleLoadedSpool(locationId: Int64?, loadedSpoolId: Int64) throws {
        let locations = try fetchLocations()
        guard let locationId, locations.first(where: { $0.id == locationId })?.kind == .cfs else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let today = String(now.prefix(10))
        let dehumidifierId = locations.first(where: { $0.kind == .dryer })?.id
        try db.run(
            """
            UPDATE spools
            SET status = 'open', location_id = ?, cfs_slot_name = NULL,
                opened_at = COALESCE(opened_at, ?), updated_at = ?
            WHERE status = 'loaded' AND location_id = ? AND id != ?
            """,
            bind: [dehumidifierId, today, now, locationId, loadedSpoolId]
        )
    }

    /// Mirrors cfs_slot_name_for_location_name(): "CFS Slot 3" -> "T1C",
    /// "External Spool Holder" -> "External".
    private static func cfsSlotName(forLocationName name: String) -> String? {
        if name == "External Spool Holder" { return "External" }
        guard name.hasPrefix("CFS Slot ") else { return nil }
        let numberText = name.replacingOccurrences(of: "CFS Slot ", with: "")
        guard let number = Int(numberText), number >= 1 else { return nil }
        let index = number - 1
        let letters = ["A", "B", "C", "D"]
        let tray = (index / 4) + 1
        let letter = letters[index % 4]
        return "T\(tray)\(letter)"
    }
}
