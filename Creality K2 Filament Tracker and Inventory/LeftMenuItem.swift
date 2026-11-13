//
//  LeftMenuItem.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The left column's navigation choices: an "Inventory" group of status
//  shortcuts (All/Open/Sealed — matching the three stat boxes above them, so
//  the numbers always agree), a "Filament Types" group for browsing by
//  material, and a "Settings" group. Selecting any of them drives what the
//  bottom-right panel shows (see ContentAreaView).
//

import Foundation

enum InventoryCategory: String, CaseIterable, Identifiable, Hashable {
    case all = "All Spools"
    case open = "Open"
    case sealed = "Sealed"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "shippingbox"
        case .open: return "shippingbox.circle"
        case .sealed: return "shippingbox.fill"
        }
    }
}

/// Browse-by-material shortcuts, replacing the old "Low Stock" smart list
/// (which turned out to be meaningless in practice). Matched by prefix
/// against a spool's stored `material` label — case-insensitive, so a
/// catalog variant like "PLA+" or "PLA Matte" still groups under `.pla`
/// rather than falling through to `.other`.
enum FilamentType: String, CaseIterable, Identifiable, Hashable {
    case pla = "PLA"
    case petg = "PETG"
    case abs = "ABS"
    case tpu = "TPU"
    case other = "Other"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pla: return "leaf.fill"
        case .petg: return "drop.fill"
        case .abs: return "flame.fill"
        case .tpu: return "waveform.path"
        case .other: return "questionmark.circle"
        }
    }

    private static let namedPrefixes: [FilamentType] = [.pla, .petg, .abs, .tpu]

    func matches(_ material: String) -> Bool {
        let upper = material.uppercased()
        switch self {
        case .other:
            return !Self.namedPrefixes.contains { $0.matches(material) }
        default:
            return upper.hasPrefix(rawValue)
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case printerConnection = "Printer Connection"
    case trackingLog = "Tracking Log"
    case trackingCorrections = "Tracking Error Corrections"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .printerConnection: return "printer"
        case .trackingLog: return "clock.arrow.circlepath"
        case .trackingCorrections: return "wrench.and.screwdriver"
        }
    }
}

enum LeftMenuItem: Hashable {
    case recentJobs
    case project(String)
    case category(InventoryCategory)
    case filamentType(FilamentType)
    case settings(SettingsPage)
}
