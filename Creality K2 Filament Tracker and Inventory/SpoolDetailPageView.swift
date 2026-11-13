import SwiftUI
import AppKit

struct SpoolEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let spool: Spool?
    var onAdd: ((Int) -> Void)?
    @State private var quantity = 1
    @State private var confirmingDelete = false
    @State private var saveError: String?

    @State private var draft: SpoolDraft
    @State private var brands: [String] = []
    @State private var types: [String] = []
    @State private var names: [CatalogNameOption] = []
    @State private var isGenericBrand = true
    init(spool: Spool? = nil, onAdd: ((Int) -> Void)? = nil) {
        self.spool = spool
        self.onAdd = onAdd
        _draft = State(initialValue: spool.map { SpoolDraft(spool: $0) } ?? SpoolDraft())
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(spool == nil ? "Add Spools" : "Edit Spool")
                .font(.title2.bold())
                .padding(16)


            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: spool == nil ? 16 : 10) {
                    if spool == nil {
                        HStack {
                            Stepper("Quantity", value: $quantity, in: 1...999)
                                .fixedSize()
                            TextField("Quantity", value: $quantity, format: .number)
                                .accessibilityLabel("Quantity")
                                .frame(width: 64)
                            Spacer()
                            Text("Sealed · Sealed Stock").foregroundStyle(.secondary)
                        }
                    }

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

                    if spool != nil {
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
                    } else {
                        pairedRow {
                            field("Weight per spool") { weightTextField($draft.originalWeightG) }
                            field("Purchased") {
                                SpoolDatePicker(title: "Purchased", value: $draft.purchasedAt)
                            }
                        }
                    }
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                }
                .padding(16)
            }
            Divider()
            HStack {
                if let saveError { Text(saveError).foregroundStyle(.red) }
                if spool != nil {
                    Button("Delete Spool", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(spool != nil ? "OK" : quantity == 1 ? "Add 1 Spool" : "Add \(quantity) Spools") {
                    do {
                        try model.saveSpoolDraft(draft, id: spool?.id, quantity: quantity)
                        if spool == nil { onAdd?(quantity) }
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 550, height: spool == nil ? 460 : 450)
        .confirmationDialog("Delete this spool?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                guard let spool else { return }
                do {
                    try model.deleteSpool(spool)
                    dismiss()
                } catch {
                    saveError = error.localizedDescription
                }
            }
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
    }

    private var canSave: Bool {
        !draft.colorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isGenericBrand || !draft.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && draft.originalWeightG > 0
            && (spool == nil ? (1...999).contains(quantity) : (0...draft.originalWeightG).contains(draft.remainingWeightG))
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
