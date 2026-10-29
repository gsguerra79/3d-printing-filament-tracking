//
//  AppModel.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Central observable state for the app: owns the database connection and
//  publishes the data SwiftUI views read. Printer sync (websocket listener)
//  hangs off this same object.
//
//  Navigation model (left column + persistent header + content area):
//  `leftSelection` is the single source of truth for what the bottom-right
//  panel shows — an inventory category's card grid, or a settings page.
//  `detailPath` is a NavigationStack path pushed with a `Spool` when a card
//  is tapped, giving a native back button to return to whichever category
//  was showing. The persistent top-right header (CFS + printer status)
//  never depends on either of these — it's always visible regardless of
//  what's selected on the left.
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
    var pendingUsageEvents: [PendingUsageEvent] = []
    var loadError: String?
    var migrationNote: String?
    var printerAddressDraft: String = ""
    var crealityCatalogMessage: String?
    var actionError: String?

    /// What the left column has selected — drives the bottom-right content
    /// area. Switching this pops any pushed spool detail, since a detail
    /// page only makes sense in the context of the category it was opened
    /// from.
    var leftSelection: LeftMenuItem = .category(.all) {
        didSet { detailPath = [] }
    }

    /// The bottom-right NavigationStack's path — pushing a `Spool` shows its
    /// detail page (with an automatic native back button); popping returns
    /// to whichever card grid or settings page is current.
    var detailPath: [Spool] = []

    // Secondary refine-filter available in the inventory grid's toolbar,
    // layered on top of whatever left-column category is already narrowed
    // to. (Material used to have its own dropdown here too, but that's
    // redundant now that Filament Types is a left-column browse option.)
    var searchText: String = ""

    /// The inventory grid's sort dropdown selection — see `filteredSpools`
    /// for how this combines with the always-on status tie-breaker.
    var sortOption: SpoolSortOption = .type

    var hideRetiredSpools = UserDefaults.standard.bool(forKey: "hideRetiredSpools") {
        didSet { UserDefaults.standard.set(hideRetiredSpools, forKey: "hideRetiredSpools") }
    }

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
    /// into the catalog table. Safe to call repeatedly — it's a full
    /// re-sync, not an additive import.
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
            pendingUsageEvents = try repository.fetchPendingUsageEvents()
            loadError = nil
            if printerAddressDraft.isEmpty {
                printerAddressDraft = settings["printer_base_url"] ?? ""
            }
            // Keep a pushed detail page's contents fresh (e.g. after an
            // autosave commits), and drop it if the spool it was showing
            // was deleted out from under it.
            if let openId = detailPath.last?.id {
                if let refreshed = spools.first(where: { $0.id == openId }) {
                    detailPath[detailPath.count - 1] = refreshed
                } else {
                    detailPath.removeLast()
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The printer's Fluidd web UI. Confirmed (2026-08-23, against the real
    /// printer via browser) that this Mac's setup serves Fluidd on the
    /// exact same host:port already configured for the Moonraker websocket
    /// connection — a single-port nginx setup, not the port-80-on-the-same-
    /// host assumption this used to make (which 404'd). So this just reuses
    /// printer_base_url's host and port as-is rather than rewriting either.
    /// Nil until a printer address is actually configured.
    var fluiddURL: URL? {
        var text = (settings["printer_base_url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), components.host != nil else { return nil }
        components.scheme = "http"
        components.path = "/"
        return components.url
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

    // MARK: - Metrics (mirrors renderMetrics() in the old app.js) — these
    // back both the left column's four stat boxes and the Inventory
    // Categories list's counts, so the numbers always agree.

    /// Spools that count toward the metrics and the inventory lists: not
    /// retired, and not sitting in a "retired" location either.
    private var activeSpools: [Spool] {
        spools.filter { spool in
            spool.status != .retired && locationKind(for: spool.locationId) != .retired
        }
    }

    var totalCount: Int { activeSpools.count }
    var openCount: Int { activeSpools.filter { $0.status == .open || $0.status == .loaded }.count }
    var sealedCount: Int { activeSpools.filter { $0.status == .sealed }.count }

    func count(for category: InventoryCategory) -> Int {
        switch category {
        case .all: return totalCount
        case .open: return openCount
        case .sealed: return sealedCount
        }
    }

    func count(for type: FilamentType) -> Int {
        activeSpools.filter { type.matches($0.material) }.count
    }

    private func locationKind(for id: Int64?) -> Location.Kind? {
        guard let id else { return nil }
        return locations.first(where: { $0.id == id })?.kind
    }

    /// Distinct materials currently in the inventory, for the material
    /// filter in the inventory grid's toolbar.
    var availableMaterials: [String] {
        Array(Set(spools.map(\.material))).sorted()
    }

    /// CFS-kind locations (the 4 slots + external holder) in display order —
    /// what the persistent header's CFS panel renders one card per.
    var cfsLocations: [Location] {
        locations.filter { $0.kind == .cfs }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Locations a spool can actually be manually loaded into — same set as
    /// cfsLocations here since that's the only `.cfs`-kind group.
    var loadableLocations: [Location] { cfsLocations }

    func spoolLoaded(atLocationId id: Int64) -> Spool? {
        spools.first { $0.locationId == id && $0.status != .retired }
    }

    /// Spool ids the usage tracker currently believes are actively printing,
    /// for the "In use" indicator on CFS cards — mirrors the
    /// usage_monitor_active_spool_ids setting the old app read for the same
    /// purpose.
    var activeSpoolIds: Set<Int64> {
        let raw = settings["usage_monitor_active_spool_ids"] ?? ""
        return Set(raw.split(separator: ",").compactMap { Int64($0) })
    }

    /// The latest printer-sync mismatch message (if any) — surfaced at the
    /// top of the Tracking Error Corrections page. Purely informational;
    /// the database never auto-acts on it (see conflictDescription in
    /// SpoolRepository.swift).
    var lastSyncConflictMessage: String? {
        guard let message = settings["slot_sync_last_message"], message.contains("mismatch") else { return nil }
        return message
    }

    // MARK: - Left-column-driven inventory grid

    /// The spools the current left-column selection covers, before the
    /// search field refines further. Settings pages have no grid, so they
    /// resolve to an empty set here.
    private var baseSpools: [Spool] {
        switch leftSelection {
        case .category(let category):
            switch category {
            case .all:
                // Deliberately the full, unfiltered spool list here (including
                // retired ones) even though the "All" stat box and this same
                // category's count(for:) stay scoped to activeSpools — Gabriel
                // wants the All list to double as a way to see retired spools,
                // without inflating the All count shown elsewhere.
                return hideRetiredSpools ? activeSpools : spools
            case .open:
                return activeSpools.filter { $0.status == .open || $0.status == .loaded }
            case .sealed:
                return activeSpools.filter { $0.status == .sealed }
            }
        case .filamentType(let type):
            return activeSpools.filter { type.matches($0.material) }
        case .settings:
            return []
        }
    }

    /// The inventory grid's actual contents: `baseSpools` further narrowed
    /// by search text, then sorted by `sortOption` (the grid's dropdown) as
    /// the primary key. Regardless of which option is chosen, a fixed
    /// status order — loaded, open, sealed, retired — is always applied as
    /// the secondary tie-breaker within each primary group, per Gabriel's
    /// request; brand/color is a final tie-breaker purely for a stable,
    /// deterministic order when everything else matches.
    var filteredSpools: [Spool] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return baseSpools
            .filter { spool in
                guard !search.isEmpty else { return true }
                let haystack = [
                    spool.material, spool.brand, spool.colorName,
                    locationName(for: spool.locationId), spool.notes,
                ].joined(separator: " ").lowercased()
                return haystack.contains(search)
            }
            .sorted { lhs, rhs in
                let primary = primarySortComparison(lhs, rhs)
                if primary != .orderedSame { return primary == .orderedAscending }

                let lhsPriority = statusSortPriority(lhs.status)
                let rhsPriority = statusSortPriority(rhs.status)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

                if lhs.brand != rhs.brand {
                    return lhs.brand.localizedStandardCompare(rhs.brand) == .orderedAscending
                }
                return lhs.colorName.localizedStandardCompare(rhs.colorName) == .orderedAscending
            }
    }

    /// The comparison driven by the grid's sort dropdown. `.status` returns
    /// `.orderedSame` for every pair — the status tie-breaker `filteredSpools`
    /// always applies right after this already expresses the exact
    /// loaded/open/sealed/retired order Gabriel wants, so encoding it twice
    /// (once here, redundantly) would just risk the two drifting apart.
    private func primarySortComparison(_ lhs: Spool, _ rhs: Spool) -> ComparisonResult {
        switch sortOption {
        case .type:
            return compareStrings(lhs.material, rhs.material)
        case .brand:
            return compareStrings(lhs.brand, rhs.brand)
        case .color:
            return compareStrings(lhs.colorName, rhs.colorName)
        case .status:
            return .orderedSame
        case .purchaseDate:
            return compareOptionalDates(lhs.purchasedAt, rhs.purchasedAt)
        case .openingDate:
            return compareOptionalDates(lhs.openedAt, rhs.openedAt)
        }
    }

    private func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }

    /// Dates are stored as "YYYY-MM-DD" strings, so a plain lexicographic
    /// compare already matches chronological order. A spool with no
    /// recorded date sorts after any spool that has one, in either
    /// direction, rather than jumping to the front the way an empty string
    /// would under a naive `<`.
    private func compareOptionalDates(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        let lhsValue = (lhs?.isEmpty == false) ? lhs : nil
        let rhsValue = (rhs?.isEmpty == false) ? rhs : nil
        switch (lhsValue, rhsValue) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (l?, r?):
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        }
    }

    /// Loaded first, then open, then sealed, then retired — the fixed
    /// secondary sort Gabriel wants applied no matter what the primary sort
    /// option is.
    private func statusSortPriority(_ status: Spool.Status) -> Int {
        switch status {
        case .loaded: return 0
        case .open: return 1
        case .sealed: return 2
        case .retired: return 3
        }
    }

    // MARK: - Catalog lookups (for the spool detail page's cascading pickers)

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

    /// Creates a spool with placeholder defaults and immediately pushes its
    /// detail page, so it opens ready to fill in — mirrors how Notes/
    /// Reminders hand you a blank item to type into rather than popping a
    /// separate "new item" dialog. Switches out of a settings page first,
    /// since a new spool belongs in an inventory category, not on top of
    /// (say) the Printer Connection page.
    @discardableResult
    func createBlankSpool() -> Int64? {
        guard let repository else { return nil }
        do {
            let id = try repository.createSpool(SpoolDraft())
            actionError = nil
            if case .settings = leftSelection {
                leftSelection = .category(.all)
            }
            reload()
            if let spool = spools.first(where: { $0.id == id }) {
                detailPath = [spool]
            }
            return id
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    func updateSpool(id: Int64, draft: SpoolDraft) {
        perform { try $0.updateSpool(id: id, draft: draft) }
    }

    func deleteSpool(_ spool: Spool) {
        perform { try $0.deleteSpool(id: spool.id) }
        detailPath.removeAll { $0.id == spool.id }
    }

    func retireSpool(_ spool: Spool) {
        perform { try $0.retireSpool(id: spool.id) }
    }

    func loadSpool(_ spool: Spool, intoLocationId locationId: Int64) {
        perform { try $0.loadSpool(id: spool.id, locationId: locationId) }
    }

    /// Moves a loaded spool out of its CFS slot/external holder back to the
    /// dehumidifier as an open spool — the card menu's "Unload" action.
    /// Does nothing if the spool isn't currently loaded anywhere.
    func unloadSpool(_ spool: Spool) {
        perform { try $0.unloadSpool(id: spool.id) }
    }

    func logUsage(spoolId: Int64, grams: Int, project: String, notes: String) {
        perform { try $0.logUsage(spoolId: spoolId, grams: grams, project: project, notes: notes) }
    }

    // MARK: - Tracking Error Corrections

    func assignPendingUsage(_ event: PendingUsageEvent, toSpoolId spoolId: Int64) {
        perform { try $0.assignPendingUsage(id: event.id, toSpoolId: spoolId) }
    }

    func discardPendingUsage(_ event: PendingUsageEvent) {
        perform { try $0.discardPendingUsage(id: event.id) }
    }
}
