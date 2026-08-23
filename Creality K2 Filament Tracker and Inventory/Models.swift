//
//  Models.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Core value types mirroring the SQLite schema used by the original
//  Python app (see filament_inventory.sqlite3 / app.py's init_db()).
//

import Foundation

struct Location: Identifiable, Hashable {
    enum Kind: String {
        case cfs, dryer, storage, retired
    }

    var id: Int64
    var name: String
    var kind: Kind
    var sortOrder: Int
}

struct Spool: Identifiable, Hashable {
    enum Status: String, CaseIterable, Hashable {
        case sealed, open, loaded, retired
    }

    var id: Int64
    var barcode: String?
    var material: String
    var brand: String
    var colorName: String
    var colorHex: String
    var diameter: String
    var originalWeightG: Int
    var remainingWeightG: Int
    var status: Status
    var locationId: Int64?
    var cfsSlotName: String?
    var purchasedAt: String?
    var openedAt: String?
    var notes: String
    var createdAt: String
    var updatedAt: String

    // Creality Print profile linkage
    var crealityFilamentId: Int64?
    var crealityBrand: String?
    var crealityType: String?
    var crealityName: String?
    var cfsMaterialCode: String?
    var cfsColorCode: String?
}

struct UsageEvent: Identifiable, Hashable {
    var id: Int64
    var spoolId: Int64
    var gramsUsed: Int
    var project: String
    var notes: String
    var createdAt: String
}

struct PendingUsageEvent: Identifiable, Hashable {
    var id: Int64
    var slotName: String
    var signature: String
    var filename: String
    var gramsPending: Int
    var basis: String
    var state: String
    var notes: String
    var createdAt: String
    var updatedAt: String
}

struct CrealityFilament: Identifiable, Hashable {
    var id: Int64
    var sourceKey: String
    var filamentId: String?
    var brand: String
    var type: String
    var name: String
    var cfsMaterialCode: String?
    var sourcePath: String?
    var rawJSON: String
    var createdAt: String
    var updatedAt: String
}

/// A recent usage-log entry joined with the spool it was drawn from, for the
/// "Recent Usage" feed. Mirrors the `usage_events JOIN spools` query in the
/// old app's fetch_bootstrap().
struct UsageEventDisplay: Identifiable, Hashable {
    var id: Int64
    var spoolId: Int64
    var gramsUsed: Int
    var project: String
    var notes: String
    var createdAt: String
    var material: String
    var brand: String
    var colorName: String
    var colorHex: String
    var crealityName: String?
}

/// Everything the Add/Edit Spool form collects, independent of whether it's
/// creating a new spool or updating an existing one. Mirrors the shape
/// `normalize_spool_payload()` produces in the old app.
struct SpoolDraft: Equatable {
    var barcode: String = ""
    var crealityFilamentId: Int64?
    var crealityBrand: String = "Generic"
    var crealityType: String = "PLA"
    var crealityName: String = ""
    var material: String = "PLA"
    var brand: String = ""
    var colorName: String = ""
    var colorHex: String = "#333333"
    var status: Spool.Status = .sealed
    var locationId: Int64?
    var originalWeightG: Int = 1000
    var remainingWeightG: Int = 1000
    var diameter: String = "1.75mm"
    var purchasedAt: String = ""
    var openedAt: String = ""
    var notes: String = ""

    init() {}

    init(spool: Spool) {
        barcode = spool.barcode ?? ""
        crealityFilamentId = spool.crealityFilamentId
        crealityBrand = spool.crealityBrand ?? (spool.brand.isEmpty ? "Generic" : spool.brand)
        crealityType = spool.crealityType ?? spool.material
        crealityName = spool.crealityName ?? ""
        material = spool.material
        brand = spool.brand
        colorName = spool.colorName
        colorHex = spool.colorHex
        status = spool.status
        locationId = spool.locationId
        originalWeightG = spool.originalWeightG
        remainingWeightG = spool.remainingWeightG
        diameter = spool.diameter
        purchasedAt = spool.purchasedAt ?? ""
        openedAt = spool.openedAt ?? ""
        notes = spool.notes
    }
}

/// A brand+type+name combination from the Creality filament catalog, used to
/// populate the cascading Name picker in the spool editor.
struct CatalogNameOption: Identifiable, Hashable {
    var id: Int64
    var name: String
}

// The standard color palette (name -> hex) lives in CFSStatusParser.swift's
// `StandardColors.options` — it was already ported there from the Python
// app's STANDARD_COLOR_OPTIONS for color-matching printer data, and the
// spool editor UI reuses that same list rather than duplicating it.

/// Default locations created on first launch — mirrors the Python app's
/// `defaults` list in init_db().
enum DefaultLocations {
    static let all: [(name: String, kind: Location.Kind, sortOrder: Int)] = [
        ("CFS Slot 1", .cfs, 10),
        ("CFS Slot 2", .cfs, 20),
        ("CFS Slot 3", .cfs, 30),
        ("CFS Slot 4", .cfs, 40),
        ("External Spool Holder", .cfs, 45),
        ("Dehumidifier", .dryer, 50),
        ("Open Storage", .storage, 60),
        ("Sealed Stock", .storage, 70),
        ("Retired / Empty", .retired, 80),
    ]
}
