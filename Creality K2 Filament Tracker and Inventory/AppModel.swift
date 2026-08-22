//
//  AppModel.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Central observable state for the app: owns the database connection and
//  publishes the data SwiftUI views read. Printer sync (websocket listener)
//  will hang off this same object in a later step.
//

import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var spools: [Spool] = []
    @Published var locations: [Location] = []
    @Published var settings: [String: String] = [:]
    @Published var loadError: String?

    let repository: SpoolRepository?

    init() {
        do {
            let db = try FilamentDatabase()
            self.repository = SpoolRepository(db: db)
        } catch {
            self.repository = nil
            self.loadError = error.localizedDescription
        }
        reload()
    }

    func reload() {
        guard let repository else { return }
        do {
            spools = try repository.fetchAllSpools()
            locations = try repository.fetchLocations()
            settings = try repository.fetchSettings()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
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
