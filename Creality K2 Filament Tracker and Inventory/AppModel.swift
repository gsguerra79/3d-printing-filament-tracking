//
//  AppModel.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Central observable state for the app: owns the database connection and
//  publishes the data SwiftUI views read. Printer sync (websocket listener)
//  will hang off this same object in a later step.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var spools: [Spool] = []
    var locations: [Location] = []
    var settings: [String: String] = [:]
    var loadError: String?
    var migrationNote: String?
    var printerAddressDraft: String = ""
    var crealityCatalogMessage: String?

    let repository: SpoolRepository?
    private(set) var printerSync: PrinterSyncEngine?

    init() {
        var repo: SpoolRepository?
        do {
            let db = try FilamentDatabase()
            migrationNote = db.migrationResult?.description
            repo = SpoolRepository(db: db)
            self.repository = repo
        } catch {
            self.repository = nil
            self.loadError = error.localizedDescription
        }

        if let repo {
            let sync = PrinterSyncEngine(repository: repo)
            sync.onInventoryChanged = { [weak self] in self?.reload() }
            self.printerSync = sync
        }

        importCrealityCatalogIfNeeded()
        reload()
        connectToPrinterIfConfigured()
    }

    /// First-launch convenience: if the catalog table is still empty (fresh
    /// install, or a migrated database that predates this feature), scan
    /// Creality Print's bundled profiles once automatically so brand/type
    /// pickers aren't empty before the user thinks to hit "refresh". Mirrors
    /// the old Python app's "import on empty table" behavior in initDb().
    private func importCrealityCatalogIfNeeded() {
        guard let repository else { return }
        guard (try? repository.crealityFilamentCount()) == 0 else { return }
        refreshCrealityCatalog()
    }

    /// Re-scans Creality Print's bundled filament profiles and upserts them
    /// into the catalog table. Safe to call repeatedly (e.g. from a toolbar
    /// button) — it's a full re-sync, not an additive import.
    func refreshCrealityCatalog() {
        guard let repository else { return }
        do {
            let imported = try repository.refreshCrealityFilaments()
            if imported == 0 {
                crealityCatalogMessage = "No Creality Print profiles found — is Creality Print installed?"
            } else {
                crealityCatalogMessage = "Imported \(imported) Creality filament profile\(imported == 1 ? "" : "s")."
            }
            settings = (try? repository.fetchSettings()) ?? settings
        } catch {
            crealityCatalogMessage = "Catalog refresh failed: \(error.localizedDescription)"
        }
    }

    func reload() {
        guard let repository else { return }
        do {
            spools = try repository.fetchAllSpools()
            locations = try repository.fetchLocations()
            settings = try repository.fetchSettings()
            loadError = nil
            if printerAddressDraft.isEmpty {
                printerAddressDraft = settings["printer_base_url"] ?? ""
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func connectToPrinterIfConfigured() {
        let address = settings["printer_base_url"] ?? ""
        guard !address.isEmpty else { return }
        printerSync?.connect(baseURL: address)
    }

    func savePrinterAddressAndReconnect() {
        guard let repository else { return }
        try? repository.setSetting("printer_base_url", printerAddressDraft)
        printerSync?.disconnect()
        printerSync?.connect(baseURL: printerAddressDraft)
    }

    func locationName(for id: Int64?) -> String {
        guard let id, let location = locations.first(where: { $0.id == id }) else {
            return "Unassigned"
        }
        return location.name
    }

    var loadedSpools: [Spool] { spools.filter { $0.status == .loaded } }
    var openSpools: [Spool] { spools.filter { $0.status == .open } }
    var sealedSpools: [Spool] { spools.filter { $0.status == .sealed } }
}
