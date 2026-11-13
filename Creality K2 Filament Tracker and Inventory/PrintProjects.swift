import Foundation
import Darwin

struct PrintProject: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var mergedInto: String?
}

struct ProjectPreferences: Codable {
    var projects: [String: PrintProject] = [:]
    var assignments: [String: String] = [:]
}

struct ProjectUsage: Hashable {
    let material: String
    let color: String
}

struct ProjectJob: Identifiable {
    let id: String
    let filename: String
    var date: String
    var usage: [ProjectUsage: Int] = [:]
    var grams: Int { usage.values.reduce(0, +) }
}

nonisolated struct ProjectCatalog: Sendable {
    var names: [String: String] = [:]
    var matches: [String: Set<String>] = [:]
    var skipped = 0

    nonisolated static func key(_ name: String) -> String {
        name.replacingOccurrences(of: #"\.(stl|obj|3mf)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    nonisolated static func scan(_ folder: URL) throws -> ProjectCatalog {
        var catalog = ProjectCatalog()
        _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard let files = FileManager.default.enumerator(atPath: folder.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        for case let path as String in files where path.lowercased().hasSuffix(".3mf") {
            let file = folder.appendingPathComponent(path)
            var info = stat()
            guard lstat(file.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_flags & UInt32(SF_DATALESS) == 0,
                  let objects = objectNames(file), !objects.isEmpty else {
                catalog.skipped += 1
                continue
            }
            let id = file.standardizedFileURL.path
            catalog.names[id] = file.deletingPathExtension().lastPathComponent
            for name in objects {
                catalog.matches[key(name), default: []].insert(id)
            }
        }
        return catalog
    }

    nonisolated private static func objectNames(_ file: URL) -> [String]? {
        let unzip = Process()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", file.path, "Metadata/model_settings.config"]
        unzip.standardOutput = handle
        unzip.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        unzip.terminationHandler = { _ in finished.signal() }
        do { try unzip.run() } catch { return nil }
        guard finished.wait(timeout: .now() + 2) == .success else {
            if unzip.isRunning { kill(unzip.processIdentifier, SIGKILL) }
            return nil
        }
        guard let data = try? Data(contentsOf: output) else { return nil }
        guard unzip.terminationStatus == 0,
              let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let nodes = try? xml.nodes(forXPath: "/config/object/metadata[@key='name']/@value") else { return nil }
        return nodes.compactMap(\.stringValue)
    }
}

extension SpoolRepository {
    func projectJobs() throws -> [ProjectJob] {
        var jobs: [String: ProjectJob] = [:]
        try db.query("""
            SELECT u.project, u.notes, u.created_at, COALESCE(u.material_at_use, s.material), COALESCE(u.color_at_use, s.color_name), u.grams_used
            FROM usage_events u JOIN spools s ON u.spool_id = s.id
            WHERE lower(u.project) LIKE '%.gcode'
            """) { row in
            guard let filename = row.stringColumn(0), let date = row.stringColumn(2) else { return }
            let marker = "Print signature: "
            let notes = row.stringColumn(1) ?? ""
            let id = notes.range(of: marker, options: .backwards).map {
                "run:" + notes[$0.upperBound...].replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
            } ?? "legacy:" + filename
            var job = jobs[id] ?? ProjectJob(id: id, filename: filename, date: date)
            job.date = max(job.date, date)
            let usage = ProjectUsage(material: row.stringColumn(3) ?? "", color: row.stringColumn(4) ?? "")
            job.usage[usage, default: 0] += row.intColumn(5)
            jobs[id] = job
        }
        return jobs.values.sorted { $0.date > $1.date }
    }
}

extension AppModel {
    var projects: [PrintProject] {
        let catalogProjects = projectCatalog.names.map { PrintProject(id: $0.key, name: $0.value) }
        return Dictionary((catalogProjects + Array(projectPreferences.projects.values)).map { ($0.id, $0) }, uniquingKeysWith: { _, saved in saved })
            .values.filter { $0.mergedInto == nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var sidebarProjects: [PrintProject] {
        let assigned = Set(printJobs.compactMap { projectForJob($0) })
        return projects.filter { assigned.contains($0.id) }
    }

    func projectCandidates(_ job: ProjectJob) -> Set<String> {
        let stem = URL(fileURLWithPath: job.filename).deletingPathExtension().lastPathComponent
        let object = stem.replacingOccurrences(of: #"_[^_]+_(?:\d+[dhms])+$"#, with: "", options: .regularExpression)
        return Set((projectCatalog.matches[ProjectCatalog.key(object)] ?? []).map(resolvedProject))
    }

    func resolvedProject(_ id: String) -> String {
        var current = id
        while let next = projectPreferences.projects[current]?.mergedInto {
            current = next
        }
        return current
    }

    func projectForJob(_ job: ProjectJob) -> String? {
        if let manual = projectPreferences.assignments[job.id] {
            return manual.isEmpty ? nil : resolvedProject(manual)
        }
        let matches = projectCandidates(job)
        return matches.count == 1 ? matches.first : nil
    }

    func projectSuggestions(_ job: ProjectJob) -> [PrintProject] {
        let matches = projectCandidates(job)
        guard matches.count > 1 else { return [] }
        var support: [String: Int] = [:]
        if let index = printJobs.firstIndex(where: { $0.id == job.id }) {
            for neighbor in printJobs[max(0, index - 6)...min(printJobs.count - 1, index + 6)] where neighbor.id != job.id {
                if let id = projectForJob(neighbor) { support[id, default: 0] += 1 }
            }
        }
        return projects.filter { matches.contains($0.id) }.sorted {
            let lhs = support[$0.id, default: 0], rhs = support[$1.id, default: 0]
            return lhs == rhs ? $0.name < $1.name : lhs > rhs
        }
    }

    func refreshProjectCatalog(_ folder: URL) async {
        guard !scanningProjects else { return }
        let hasAccess = folder.startAccessingSecurityScopedResource()
        defer { if hasAccess { folder.stopAccessingSecurityScopedResource() } }
        scanningProjects = true
        defer { scanningProjects = false }
        do {
            let catalog = try await Task.detached(priority: .utility) { try ProjectCatalog.scan(folder) }.value
            try repository?.setSetting("project_catalog_folder", folder.path)
            if let bookmark = try? folder.bookmarkData(options: .withSecurityScope) {
                try repository?.setSetting("project_catalog_bookmark", bookmark.base64EncodedString())
            }
            projectFolder = folder
            projectCatalog = catalog
        } catch {
            actionError = error.localizedDescription
        }
    }

    func saveProjectPreferences(_ preferences: ProjectPreferences) {
        do {
            let data = try JSONEncoder().encode(preferences)
            try repository?.setSetting("project_preferences", String(decoding: data, as: UTF8.self))
            projectPreferences = preferences
        } catch {
            actionError = error.localizedDescription
        }
    }
}
