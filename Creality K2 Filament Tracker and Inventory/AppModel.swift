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
    var usageEvents: [UsageEventDisplay] = []
    var loadError: String?
    var migrationNote: String?
    var printerAddressDraft: String = ""
    var crealityCatalogMessage: String?
    var actionError: String?

    // Filter state for the inventory grid — mirrors the old web app's
    // search/material/location/status filter bar.
    var searchText: String = ""
    var materialFilter: String = ""
    var locationFilter: Int64?
    var statusFilter: Spool.Status?

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
            usageEvents = try repository.fetchRecentUsageEvents(limit: 50)
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

    // MARK: - Metrics (mirrors renderMetrics() in the old app.js)

    /// Spools that count toward the metrics row and the inventory grid: not
    /// retired, and not sitting in a "retired" location either.
    private var activeSpools: [Spool] {
        spools.filter { spool in
            spool.status != .retired && locationKind(for: spool.locationId) != .retired
        }
    }

    var totalCount: Int { activeSpools.count }
    var openCount: Int { activeSpools.filter { $0.status == .open || $0.status == .loaded }.count }
    var sealedCount: Int { activeSpools.filter { $0.status == .sealed }.count }
    var lowStockCount: Int { activeSpools.filter { $0.remainingWeightG < 200 }.count }

    private func locationKind(for id: Int64?) -> Location.Kind? {
        guard let id else { return nil }
        return locations.first(where: { $0.id == id })?.kind
    }

    /// Distinct materials currently in the inventory, for the material
    /// filter dropdown.
    var availableMaterials: [String] {
        Array(Set(spools.map(\.material))).sorted()
    }

    /// CFS-kind locations (the 4 slots + external holder) in display order —
    /// what the CFS panel renders one card per.
    var cfsLocations: [Location] {
        locations.filter { $0.kind == .cfs }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Locations a spool can actually be manually loaded into — mirrors
    /// loadableLocations() (CFS slots + external holder, same set as
    /// cfsLocations here since that's the only `.cfs`-kind group).
    var loadableLocations: [Location] { cfsLocations }

    func spoolLoaded(atLocationId id: Int64) -> Spool? {
        spools.first { $0.locationId == id && $0.status != .retired }
    }

    /// Spool ids the usage tracker currently believes are actively printing,
    /// for the "In use" flag on CFS slot cards — mirrors the
    /// usage_monitor_active_spool_ids setting the old app read for the same
    /// purpose.
    var activeSpoolIds: Set<Int64> {
        let raw = settings["usage_monitor_active_spool_ids"] ?? ""
        return Set(raw.split(separator: ",").compactMap { Int64($0) })
    }

    /// The inventory grid's contents after search + material/location/status
    /// filters — mirrors filteredSpools().
    var filteredSpools: [Spool] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return spools.filter { spool in
            let haystackMatches: Bool = {
                guard !search.isEmpty else { return true }
                let haystack = [
                    spool.material, spool.brand, spool.colorName,
                    locationName(for: spool.locationId), spool.notes,
                ].joined(separator: " ").lowercased()
                return haystack.contains(search)
            }()
            return haystackMatches
                && (materialFilter.isEmpty || spool.material == materialFilter)
                && (locationFilter == nil || spool.locationId == locationFilter)
                && (statusFilter == nil || spool.status == statusFilter)
        }
    }

    // MARK: - Catalog lookups (for the spool editor's cascading pickers)

    func catalogBrands() -> [String] {
        guard let repository else { return [] }
        return (try? repository.catalogBrands()) ?? []
    }

    func catalogTypes(forBrand brand: String) -> [String] {
        guard let repository else { return [] }
        return (try? repository.catalogTypes(forBrand: brand)) ?? []
    }

    func catalogNames(forBrand brand: String, type: String) -> [CatalogNameOption] {
        guard let repository else { return [] }
        return (try? repository.catalogNames(forBrand: brand, type: type)) ?? []
    }

    // MARK: - Editing actions

    /// Runs a repository mutation, surfaces any failure via `actionError`,
    /// and reloads the in-memory state on success so the UI reflects it
    /// immediately.
    private func perform(_ action: (SpoolRepository) throws -> Void) {
        guard let repository else { return }
        do {
            try action(repository)
            actionError = nil
            reload()
        } catch {
            actionError = error.localizedDescription
        }
    }

    func createSpool(_ draft: SpoolDraft) {
        perform { try $0.createSpool(draft) }
    }

    func updateSpool(id: Int64, draft: SpoolDraft) {
        perform { try $0.updateSpool(id: id, draft: draft) }
    }

    func deleteSpool(_ spool: Spool) {
        perform { try $0.deleteSpool(id: spool.id) }
    }

    func retireSpool(_ spool: Spool) {
        perform { try $0.retireSpool(id: spool.id) }
    }

    func loadSpool(_ spool: Spool, intoLocationId locationId: Int64) {
        perform { try $0.loadSpool(id: spool.id, locationId: locationId) }
    }

    func logUsage(spoolId: Int64, grams: Int, project: String, notes: String) {
        perform { try $0.logUsage(spoolId: spoolId, grams: grams, project: project, notes: notes) }
    }
}
