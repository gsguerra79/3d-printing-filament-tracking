import SwiftUI
import UniformTypeIdentifiers

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    let projectID: String?
    @State private var importing = false
    @State private var renaming = false
    @State private var name = ""
    @State private var choosingMerge = false
    @State private var mergeSearch = ""
    @State private var mergeTarget: PrintProject?
    @State private var selection = Set<String>()

    private var project: PrintProject? { model.projects.first { $0.id == projectID } }

    private var jobs: [ProjectJob] {
        guard let projectID else { return model.printJobs }
        return model.printJobs.filter { model.projectForJob($0) == projectID }
    }

    private var totals: [ProjectUsage: Int] {
        jobs.reduce(into: [:]) { total, job in
            for (type, grams) in job.usage { total[type, default: 0] += grams }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project?.name ?? "Recent Jobs").font(.title2.bold())
                Spacer()
                if let project {
                    Button("Rename…") {
                        name = project.name
                        renaming = true
                    }
                    Button("Merge Into…") {
                        mergeSearch = ""
                        choosingMerge = true
                    }
                    .disabled(!model.sidebarProjects.contains { $0.id != project.id })
                    .popover(isPresented: $choosingMerge) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Search projects", text: $mergeSearch)
                            let query = mergeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                            let destinations = model.sidebarProjects.filter {
                                $0.id != project.id && (query.isEmpty || $0.name.localizedStandardContains(query))
                            }
                            if destinations.isEmpty {
                                Text("No matching projects").foregroundStyle(.secondary)
                            } else {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(destinations) { target in
                                            Button {
                                                choosingMerge = false
                                                mergeTarget = target
                                            } label: {
                                                Text(target.name)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .padding(6)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .frame(height: 240)
                            }
                        }
                        .padding(12)
                        .frame(width: 360)
                    }
                } else {
                    if model.scanningProjects { ProgressView().controlSize(.small) }
                    if let folder = model.projectFolder {
                        Button("Rescan") { Task { await model.refreshProjectCatalog(folder) } }
                            .disabled(model.scanningProjects)
                    }
                    Button("Choose .3mf Folder…") { importing = true }
                        .disabled(model.scanningProjects)
                }
            }

            if project != nil {
                Text("\(jobs.count) jobs · \(totals.values.reduce(0, +)) g recorded").font(.headline)
                Text(totals.sorted { $0.value > $1.value }.map { "\($0.key.material) \($0.key.color) · \($0.value) g" }.joined(separator: "    "))
                    .foregroundStyle(.secondary)
            } else if model.projectFolder == nil {
                Text("Choose the folder containing your saved Creality Print projects.").foregroundStyle(.secondary)
            } else {
                Text("\(model.projectCatalog.names.count) project files read · \(model.projectCatalog.skipped) skipped")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Print jobs").font(.headline)
                Spacer()
                Menu("Move Selected Jobs") {
                    let sidebar = model.sidebarProjects
                    let sidebarIDs = Set(sidebar.map(\.id))
                    let more = model.projects.filter { !sidebarIDs.contains($0.id) }

                    ForEach(sidebar) { target in
                        Button(target.name) { assign(selection, to: target.id) }
                    }
                    if !more.isEmpty {
                        Menu("More Projects") {
                            ForEach(more) { target in
                                Button(target.name) { assign(selection, to: target.id) }
                            }
                        }
                    }
                    Divider()
                    Button("Unassigned") { assign(selection, to: "") }
                }
                .disabled(selection.isEmpty)
            }

            List(selection: $selection) {
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(job.filename)
                            Spacer()
                            Text("\(job.grams) g").monospacedDigit()
                        }
                        HStack {
                            Text(job.date).foregroundStyle(.secondary)
                            if let id = model.projectForJob(job),
                               let assigned = model.projects.first(where: { $0.id == id }) {
                                Text(assigned.name).foregroundStyle(.secondary)
                            } else if let suggestion = model.projectSuggestions(job).first {
                                Button("Assign to \(suggestion.name)") { assign([job.id], to: suggestion.id) }
                                    .buttonStyle(.bordered)
                            } else {
                                Text("Unassigned").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                    .tag(job.id)
                }
            }
        }
        .padding(12)
        .onChange(of: projectID) { selection = [] }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): Task { await model.refreshProjectCatalog(folder) }
            case .failure(let error): model.actionError = error.localizedDescription
            }
        }
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Project name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard var project, !trimmed.isEmpty else { return }
                project.name = trimmed
                var preferences = model.projectPreferences
                preferences.projects[project.id] = project
                model.saveProjectPreferences(preferences)
            }
        }
        .alert("Merge Projects?", isPresented: Binding(
            get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }
        ), presenting: mergeTarget) { target in
            Button("Cancel", role: .cancel) {}
            Button("Merge") {
                guard var project else { return }
                project.mergedInto = target.id
                var preferences = model.projectPreferences
                preferences.projects[project.id] = project
                preferences.projects[target.id] = target
                model.saveProjectPreferences(preferences)
                model.leftSelection = .project(target.id)
            }
        } message: { target in
            Text("Move all jobs from \(project?.name ?? "") into \(target.name)?")
        }
    }

    private func assign(_ jobs: Set<String>, to projectID: String) {
        var preferences = model.projectPreferences
        if let target = model.projects.first(where: { $0.id == projectID }) {
            preferences.projects[projectID] = target
        }
        for id in jobs { preferences.assignments[id] = projectID }
        model.saveProjectPreferences(preferences)
        selection = []
    }
}
