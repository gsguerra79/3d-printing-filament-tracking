//
//  AppModel.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Central observable state for the app: owns the database connection and
//  publishes the data SwiftUI views read.
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

        reload()
        connectToPrinterIfConfigured()
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
