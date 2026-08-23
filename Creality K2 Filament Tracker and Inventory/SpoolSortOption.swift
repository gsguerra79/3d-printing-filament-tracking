//
//  SpoolSortOption.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Drives the sort dropdown at the top of InventoryGridView. Whichever
//  option is chosen is always the *primary* sort key; AppModel.filteredSpools
//  then always applies the same secondary tie-breaker on top of it —
//  loaded first, then open, then sealed, then retired — per Gabriel's
//  request that that ordering hold "no matter which one you chose."
//

import Foundation

enum SpoolSortOption: String, CaseIterable, Identifiable, Hashable {
    case type = "Type"
    case status = "Status"
    case purchaseDate = "Purchase Date"
    case openingDate = "Opening Date"

    var id: String { rawValue }
}
