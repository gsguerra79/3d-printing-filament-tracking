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
}
