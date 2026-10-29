//
//  InventoryGridView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The bottom-right panel's card grid for a selected Inventory Category or
//  Filament Type — the rich, colorful `SpoolCardView` grid from the original
//  web app (weight bars, status/location tags), not a plain Table. Tapping a
//  card pushes SpoolDetailPageView via NavigationLink(value:); its own menu
//  handles Load/Unload/Retire without triggering that push (Edit does, since
//  it's the same destination). Log Usage and Delete both live on the detail
//  page now rather than cluttering this quick menu — reach them via Edit.
//
//  Deliberately has no `.toolbar`/`.navigationTitle`/`.searchable` — the
//  title, search field, and Add button all live in this view's own header
//  row instead, so the app's top window bar stays fixed on just the app
//  name rather than changing per screen.
//

import SwiftUI

struct InventoryGridView: View {
    @Environment(AppModel.self) private var model

    /// Display title only — the actual filtering already happened in
    /// `AppModel.filteredSpools`, keyed off `leftSelection`.
    let title: String

    @State private var loadTarget: Spool?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Picker("Sort by", selection: $model.sortOption) {
                    ForEach(SpoolSortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                TextField("Search spools", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Button {
                    model.createBlankSpool()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
            }
            .padding(16)

            if case .category(.all) = model.leftSelection {
                Toggle("Hide retired", isOn: $model.hideRetiredSpools)
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.filteredSpools) { spool in
                        NavigationLink(value: spool) {
                            SpoolCardView(
                                spool: spool,
                                locationName: model.locationName(for: spool.locationId),
                                isActive: model.activeSpoolIds.contains(spool.id),
                                onEdit: { model.detailPath.append(spool) },
                                onLoad: { loadTarget = spool },
                                onUnload: { model.unloadSpool(spool) },
                                onRetire: { model.retireSpool(spool) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding([.horizontal, .bottom], 16)
            }
            .overlay {
                if model.filteredSpools.isEmpty {
                    ContentUnavailableView(
                        title == InventoryCategory.all.rawValue ? "No Spools Yet" : "No Spools Here",
                        systemImage: "tray",
                        description: Text("Try a different filter, or click + Add to add one.")
                    )
                }
            }
        }
        .popover(item: $loadTarget) { spool in
            LoadSpoolPopoverView(spool: spool) { locationId in
                model.loadSpool(spool, intoLocationId: locationId)
            }
        }
    }
}
