//
//  ContentAreaView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The bottom-right panel. Its root view switches on the left column's
//  selection (a category's card grid, or a settings page); a NavigationStack
//  wraps all of it so tapping a card pushes SpoolDetailPageView with a real,
//  native back button that returns to whichever root was showing — exactly
//  the "back button to return to the previous inventory category view"
//  behavior from the spec, without needing a second navigation column.
//

import SwiftUI

struct ContentAreaView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $model.detailPath) {
            root
                .navigationDestination(for: Spool.self) { spool in
                    SpoolDetailPageView(spool: spool)
                }
        }
    }

    @ViewBuilder
    private var root: some View {
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
