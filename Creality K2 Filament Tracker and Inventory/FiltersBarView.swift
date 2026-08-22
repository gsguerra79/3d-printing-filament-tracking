//
//  FiltersBarView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Search + material/location/status filters above the inventory grid —
//  mirrors the filter bar in the old web app (filteredSpools()).
//

import SwiftUI

struct FiltersBarView: View {
    @Binding var searchText: String
    @Binding var materialFilter: String
    @Binding var locationFilter: Int64?
    @Binding var statusFilter: Spool.Status?
    var materials: [String]
    var locations: [Location]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search spools", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(minWidth: 180, maxWidth: 260)

            Picker("Material", selection: $materialFilter) {
                Text("All Materials").tag("")
                ForEach(materials, id: \.self) { material in
                    Text(material).tag(material)
                }
            }
            .labelsHidden()

            Picker("Location", selection: $locationFilter) {
                Text("All Locations").tag(Int64?.none)
                ForEach(locations) { location in
                    Text(location.name).tag(Optional(location.id))
                }
            }
            .labelsHidden()

            Picker("Status", selection: $statusFilter) {
                Text("All Statuses").tag(Spool.Status?.none)
                ForEach(Spool.Status.allCases, id: \.self) { status in
                    Text(status.rawValue.capitalized).tag(Optional(status))
                }
            }
            .labelsHidden()

            Spacer()
        }
    }
}
