//
//  SpoolDetailPageView.swift
//  Creality K2 Filament Tracker and Inventory
//
//  A single spool's detail page — pushed onto the bottom-right
//  NavigationStack from a card's tap (see InventoryGridView /
//  PersistentHeaderView). Built as a plain compact form (no Form/Section
//  chrome, paired fields side by side) rather than the old full-width
//  stacked layout, specifically to minimize scrolling: no Color Hex,
//  Diameter, or Barcode fields, and every remaining field pairs up with
//  another on the same row. Fields edit in place and autosave (debounced
//  ~450ms) rather than requiring an explicit Save button, matching how
//  native macOS inspectors (Notes, Reminders, Finder's Get Info) behave.
//
//  Deliberately has no `.toolbar`/`.navigationTitle` — Back/Load/Log Usage/
//  Retire live in this view's own header row, and Delete is a separated
//  button at the bottom, so the app's top window bar stays fixed on just
//  the app name rather than changing per screen.
//

import SwiftUI

struct SpoolDetailPageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let spool: Spool

    @State private var draft: SpoolDraft
    @State private var brands: [String] = []
    @State private var types: [String] = []
    @State private var names: [CatalogNameOption] = []
    @State private var isGenericBrand = true
    @State private var saveTask: Task<Void, Never>?
    @State private var showingLoadPopover = false
    @State private var showingUsagePopover = false
    @State private var confirmingDelete = false

    init(spool: Spool) {
        self.spool = spool
        _draft = State(initialValue: SpoolDraft(spool: spool))
    }

    var body: some View {
        VStack(spacing: 0) {
            actionRow

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    pairedRow {
                        field("Brand") {
                            Picker("", selection: $draft.crealityBrand) {
                                ForEach(brands, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: draft.crealityBrand) { _, newValue in
                                isGenericBrand = newValue.caseInsensitiveCompare("Generic") == .orderedSame
                                refreshTypes()
                            }
                        }
                        field("Type") {
                            Picker("", selection: $draft.crealityType) {
                                ForEach(types, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: draft.crealityType) { _, _ in refreshNames() }
                        }
                    }
                    if isGenericBrand {
                        TextField("Custom Brand", text: $draft.brand)
                            .textFieldStyle(.roundedBorder)
                    }
                    pairedRow {
                        field("Name") {
                            Picker("", selection: $draft.crealityFilamentId) {
                                ForEach(names) { option in
                                    Text(option.name).tag(Optional(option.id))
                                }
                            }
                            .labelsHidden()
                        }
                        field("Color") {
                            Picker("", selection: $draft.colorName) {
                                ForEach(StandardColors.options.map(\.name), id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: draft.colorName) { _, newValue in
                                if let match = StandardColors.options.first(where: { $0.name == newValue }) {
                                    draft.colorHex = match.hex
                                }
                            }
                        }
                    }

                    pairedRow {
                        field("Status") {
                            Picker("", selection: $draft.status) {
                                ForEach(Spool.Status.allCases, id: \.self) { status in
                                    Text(status.rawValue.capitalized).tag(status)
                                }
                            }
                            .labelsHidden()
                        }
                        field("Location") {
                            Picker("", selection: $draft.locationId) {
                                Text("Unassigned").tag(Int64?.none)
                                ForEach(model.locations) { location in
                                    Text(location.name).tag(Optional(location.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    pairedRow {
                        field("Original Weight") { weightTextField($draft.originalWeightG) }
                        field("Remaining Weight") { weightTextField($draft.remainingWeightG) }
                    }

                    pairedRow {
                        field("Purchased") {
                            TextField("YYYY-MM-DD", text: $draft.purchasedAt)
                                .textFieldStyle(.roundedBorder)
                        }
                        field("Opened") {
                            TextField("YYYY-MM-DD", text: $draft.openedAt)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete Spool", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .confirmationDialog(
            "Delete this spool?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.deleteSpool(spool)
            }
        } message: {
            Text("This can't be undone.")
        }
        .onAppear {
            isGenericBrand = draft.crealityBrand.caseInsensitiveCompare("Generic") == .orderedSame
            refreshBrands()
        }
        .onChange(of: draft) { _, newValue in
            saveTask?.cancel()
            let id = spool.id
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                model.updateSpool(id: id, draft: newValue)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            Spacer()
            Button {
                showingLoadPopover = true
            } label: {
                Label("Load…", systemImage: "tray.and.arrow.down")
            }
            .popover(isPresented: $showingLoadPopover) {
                LoadSpoolPopoverView(spool: spool) { locationId in
                    model.loadSpool(spool, intoLocationId: locationId)
                }
            }
            Button {
                showingUsagePopover = true
            } label: {
                Label("Log Usage…", systemImage: "minus.circle")
            }
            .popover(isPresented: $showingUsagePopover) {
                LogUsagePopoverView(spool: spool) { grams, project, notes in
                    model.logUsage(spoolId: spool.id, grams: grams, project: project, notes: notes)
                }
            }
            Button {
                model.retireSpool(spool)
            } label: {
                Label("Retire", systemImage: "archivebox")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 14) {
            SpoolGraphic(colorHex: draft.colorHex, diameter: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title3.weight(.semibold))
                Text(draft.material)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func pairedRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            content()
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func weightTextField(_ value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            TextField("grams", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text("g")
                .foregroundStyle(.secondary)
        }
    }

    private var headerTitle: String {
        let brand = draft.brand.isEmpty ? draft.crealityBrand : draft.brand
        return draft.colorName.isEmpty ? brand : "\(brand) \(draft.colorName)"
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
