//
//  SpoolEditorSheet.swift
//  Creality K2 Filament Tracker and Inventory
//
//  The Add/Edit Spool dialog — mirrors the old web app's spoolDialog: a
//  cascading Brand -> Type -> Name picker backed by the Creality filament
//  catalog (falling back to a free-text brand when "Generic" is chosen,
//  same as isGenericBrand/setGenericBrandVisibility()), a standard color
//  picker, status/location, weight, and notes.
//

import SwiftUI

struct SpoolEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var existing: Spool?
    var onSave: (SpoolDraft) -> Void

    @State private var draft: SpoolDraft
    @State private var brands: [String] = []
    @State private var types: [String] = []
    @State private var names: [CatalogNameOption] = []
    @State private var isGenericBrand = true

    init(existing: Spool?, onSave: @escaping (SpoolDraft) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _draft = State(initialValue: existing.map(SpoolDraft.init(spool:)) ?? SpoolDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filament Profile") {
                    Picker("Brand", selection: $draft.crealityBrand) {
                        ForEach(brands, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: draft.crealityBrand) { _, newValue in
                        isGenericBrand = newValue.caseInsensitiveCompare("Generic") == .orderedSame
                        refreshTypes()
                    }

                    if isGenericBrand {
                        TextField("Custom Brand", text: $draft.brand)
                    }

                    Picker("Type", selection: $draft.crealityType) {
                        ForEach(types, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: draft.crealityType) { _, _ in refreshNames() }

                    Picker("Name", selection: $draft.crealityFilamentId) {
                        ForEach(names) { option in
                            Text(option.name).tag(Optional(option.id))
                        }
                    }
                }

                Section("Color") {
                    Picker("Color", selection: $draft.colorName) {
                        ForEach(StandardColors.options.map(\.name), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onChange(of: draft.colorName) { _, newValue in
                        if let match = StandardColors.options.first(where: { $0.name == newValue }) {
                            draft.colorHex = match.hex
                        }
                    }
                    HStack {
                        Circle()
                            .fill(Color(hex: draft.colorHex))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.3)))
                        TextField("Hex", text: $draft.colorHex)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                    }
                }

                Section("Status & Location") {
                    Picker("Status", selection: $draft.status) {
                        ForEach(Spool.Status.allCases, id: \.self) { status in
                            Text(status.rawValue.capitalized).tag(status)
                        }
                    }
                    Picker("Location", selection: $draft.locationId) {
                        Text("Unassigned").tag(Int64?.none)
                        ForEach(model.locations) { location in
                            Text(location.name).tag(Optional(location.id))
                        }
                    }
                }

                Section("Weight") {
                    HStack {
                        Text("Original")
                        Spacer()
                        TextField("grams", value: $draft.originalWeightG, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Remaining")
                        Spacer()
                        TextField("grams", value: $draft.remainingWeightG, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                    Picker("Diameter", selection: $draft.diameter) {
                        Text("1.75mm").tag("1.75mm")
                        Text("2.85mm").tag("2.85mm")
                    }
                }

                Section("Details") {
                    TextField("Barcode", text: $draft.barcode)
                    TextField("Purchased (YYYY-MM-DD)", text: $draft.purchasedAt)
                    TextField("Opened (YYYY-MM-DD)", text: $draft.openedAt)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Add Spool" : "Edit Spool")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .onAppear {
            isGenericBrand = draft.crealityBrand.caseInsensitiveCompare("Generic") == .orderedSame
            refreshBrands()
        }
    }

    private func refreshBrands() {
        brands = model.catalogBrands()
        if !brands.isEmpty, !brands.contains(draft.crealityBrand) {
            draft.crealityBrand = brands.first ?? draft.crealityBrand
        }
        refreshTypes()
    }

    private func refreshTypes() {
        types = model.catalogTypes(forBrand: draft.crealityBrand)
        if !types.isEmpty, !types.contains(draft.crealityType) {
            draft.crealityType = types.first ?? draft.crealityType
        }
        refreshNames()
    }

    private func refreshNames() {
        names = model.catalogNames(forBrand: draft.crealityBrand, type: draft.crealityType)
        if let currentId = draft.crealityFilamentId, names.contains(where: { $0.id == currentId }) {
            return
        }
        draft.crealityFilamentId = names.first?.id
    }
}
