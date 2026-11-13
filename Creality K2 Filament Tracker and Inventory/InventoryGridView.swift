//
//  InventoryGridView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Inventory cards with explicit actions in each card menu.

import SwiftUI

struct InventoryGridView: View {
    @Environment(AppModel.self) private var model

    /// Display title only — the actual filtering already happened in
    /// `AppModel.filteredSpools`, keyed off `leftSelection`.
    let title: String

    @State private var loadTarget: Spool?
    @State private var showingAdd = false
    @State private var addedMessage: String?


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
                    showingAdd = true
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

            if let addedMessage {
                Label(addedMessage, systemImage: "checkmark.circle")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.filteredSpools) { spool in
                        SpoolCardView(
                            spool: spool,
                            locationName: model.locationName(for: spool.locationId),
                            isActive: model.activeSpoolIds.contains(spool.id),
                            onEdit: { model.editingSpool = spool },
                            onLoad: { loadTarget = spool },
                            onUnload: { model.unloadSpool(spool) },
                            onRetire: { model.retireSpool(spool) }
                        )
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
        .sheet(isPresented: $showingAdd) {
            SpoolEditorView { count in
                addedMessage = count == 1 ? "1 spool added to Sealed Stock." : "\(count) spools added to Sealed Stock."
            }
        }
        .popover(item: $loadTarget) { spool in
            LoadSpoolPopoverView(spool: spool) { locationId in
                model.loadSpool(spool, intoLocationId: locationId)
            }
        }
    }
}
