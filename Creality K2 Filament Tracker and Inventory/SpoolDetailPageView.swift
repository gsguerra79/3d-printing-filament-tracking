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
//  Deliberately has no `.toolbar`/`.navigationTitle` — Back/Load/
//  Retire live in this view's own header row, and Delete is a separated
//  button at the bottom, so the app's top window bar stays fixed on just
//  the app name rather than changing per screen.
//

import SwiftUI
import AppKit

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
                            HStack(spacing: 6) {
                                TextField("Color name", text: $draft.colorName)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Color name")
                                ColorPicker("Spool icon color", selection: iconColor, supportsOpacity: false)
                                    .labelsHidden()
                                    .fixedSize()
                                    .help("Choose the spool icon color")
                                Menu {
                                    ForEach(StandardColors.options, id: \.name) { color in
                                        Button(color.name) {
                                            draft.colorName = color.name
                                            draft.colorHex = color.hex
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Choose a standard color")
                                .accessibilityLabel("Standard colors")
                            }
                            .onChange(of: draft.colorName) { _, newValue in
                                if let match = StandardColors.options.first(where: {
                                    $0.name.caseInsensitiveCompare(newValue) == .orderedSame
                                }) {
                                    draft.colorHex = match.hex
                                }
                            }
                        }
                    }

                    pairedRow {
                        field("Status") {
                            Picker("", selection: statusSelection) {
                                ForEach(Spool.Status.allCases, id: \.self) { status in
                                    Text(status.rawValue.capitalized).tag(status)
                                }
                            }
                            .labelsHidden()
                        }
                        field("Location") {
                            Picker("", selection: $draft.locationId) {
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
                            SpoolDatePicker(title: "Purchased", value: $draft.purchasedAt)
                        }
                        field("Opened") {
                            SpoolDatePicker(title: "Opened", value: $draft.openedAt)
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
            if draft.locationId == nil {
                let locationName = draft.status == .sealed ? "Sealed Stock"
                    : draft.status == .retired ? "Retired / Empty" : "Dehumidifier"
                draft.locationId = model.locations.first { $0.name == locationName }?.id
            }
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

    private var statusSelection: Binding<Spool.Status> {
        Binding(
            get: { draft.status },
            set: { status in
                draft.status = status
                if status == .sealed {
                    draft.locationId = model.locations.first { $0.name == "Sealed Stock" }?.id
                }
            }
        )
    }

    private var iconColor: Binding<Color> {
        Binding(
            get: { Color(hex: draft.colorHex) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                draft.colorHex = String(
                    format: "#%02x%02x%02x",
                    Int((rgb.redComponent * 255).rounded()),
                    Int((rgb.greenComponent * 255).rounded()),
                    Int((rgb.blueComponent * 255).rounded())
                )
            }
        )
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

/// Keeps optional inventory dates in their existing YYYY-MM-DD storage format.
private struct SpoolDatePicker: View {
    let title: String
    @Binding var value: String
    @State private var showingCalendar = false

    private var selectedDate: Binding<Date> {
        Binding(
            get: { Self.formatter.date(from: value) ?? Date() },
            set: { value = Self.formatter.string(from: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showingCalendar = true
            } label: {
                HStack {
                    Text(value.isEmpty ? "Choose date…" : selectedDate.wrappedValue.formatted(date: .abbreviated, time: .omitted))
                    Spacer(minLength: 4)
                    Image(systemName: "calendar")
                }
            }
            .accessibilityLabel("\(title) date")
            .popover(isPresented: $showingCalendar) {
                VStack(alignment: .trailing, spacing: 12) {
                    DatePicker(title, selection: selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    HStack {
                        Button("Today") { selectedDate.wrappedValue = Date() }
                        Spacer()
                        Button("Done") { showingCalendar = false }
                    }
                }
                .padding()
            }
            if !value.isEmpty {
                Button {
                    value = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear date")
                .accessibilityLabel("Clear \(title.lowercased()) date")
            }
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
