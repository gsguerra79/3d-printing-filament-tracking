//
//  ContentAreaView.swift
//  Creality K2 Filament Tracker and Inventory
//
import SwiftUI

struct ContentAreaView: View {
    @Environment(AppModel.self) private var model

    @ViewBuilder
    var body: some View {
        switch model.leftSelection {
        case .category(let category):
            InventoryGridView(title: category.rawValue)
        case .filamentType(let type):
            InventoryGridView(title: type.rawValue)
        case .settings(.printerConnection):
            PrinterSettingsView()
        case .settings(.trackingLog):
            UsageHistoryView()
        case .settings(.trackingCorrections):
            TrackingCorrectionsView()
        }
    }
}
