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
    enum Status: String, CaseIterable {
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
