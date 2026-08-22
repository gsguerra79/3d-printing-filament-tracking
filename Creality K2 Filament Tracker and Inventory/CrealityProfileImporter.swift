//
//  CrealityProfileImporter.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Reads the Creality Print app's bundled filament profile catalog
//  (Contents/Resources/profiles/<folder>/filament/*.json) and turns it into
//  the rows the `creality_filaments` table wants. This is a straight port of
//  the old Python app's creality_source_records()/import_creality_filaments():
//  same heuristics for deriving brand/type/name, same source_key dedup rule,
//  same three settings keys recorded after a refresh.
//
//  Deliberately read-only with respect to Creality Print itself — this only
//  ever reads the JSON profiles it ships with, never touches the app.
//

import Foundation

struct CrealityFilamentRecord {
    let sourceKey: String
    let filamentId: String
    let brand: String
    let type: String
    let name: String
    let cfsMaterialCode: String?
    let sourcePath: String
    let rawJSON: String
}

enum CrealityProfileImporter {
    /// Where Creality Print itself stores its bundled resources. Update this
    /// if a future Creality Print version moves it.
    static let resourcesRoot = URL(fileURLWithPath: "/Applications/Creality Print.app/Contents/Resources")

    /// Recognized filament-type codes, used to guess a profile's material
    /// when the profile itself doesn't state `filament_type` directly.
    /// Order matters: more specific codes (e.g. "PLA-CF") must be checked
    /// before their generic prefix ("PLA" isn't in this list, but "PA" is a
    /// substring of "PA-CF", "PA-GF", etc., so those need to come first).
    private static let knownMaterials = [
        "PLA-CF", "PLA-AERO", "PETG-CF", "PETG", "ABS-GF", "ABS", "ASA-AERO", "ASA", "TPU",
        "PA6-CF", "PA-CF", "PA-GF", "PA", "PET-CF", "PPS-CF", "PPS", "PPA-CF", "PPA-GF", "PC",
        "PVA", "BVOH", "PEEK", "PCTG", "HIPS", "PP-CF", "PP-GF", "PP", "PE-CF", "PE", "EVA", "PHA",
    ]

    /// Walks the Creality Print profile catalog and returns one record per
    /// distinct (brand, type, name, filament_id) combination, sorted for
    /// stable diffs. Returns an empty array (never throws) if Creality Print
    /// isn't installed or the profiles folder is missing — importing the
    /// catalog is best-effort, not required for the app to function.
    static func sourceRecords() -> [CrealityFilamentRecord] {
        let profilesRoot = resourcesRoot.appendingPathComponent("profiles")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: profilesRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var records: [String: CrealityFilamentRecord] = [:]
        let folderURLs = (try? fm.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for folderURL in folderURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var folderIsDir: ObjCBool = false
            guard fm.fileExists(atPath: folderURL.path, isDirectory: &folderIsDir), folderIsDir.boolValue else { continue }
            let folder = folderURL.lastPathComponent
            let filamentDir = folderURL.appendingPathComponent("filament")
            let jsonFiles = ((try? fm.contentsOfDirectory(
                at: filamentDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

            for fileURL in jsonFiles where fileURL.pathExtension.lowercased() == "json" {
                guard
                    let data = try? Data(contentsOf: fileURL),
                    let profile = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                    (profile["type"] as? String) == "filament"
                else { continue }

                let filamentId = cleanText(profile["filament_id"])
                guard !filamentId.isEmpty else { continue }

                let profileName = cleanText(profile["name"])
                let nameSource = profileName.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : profileName
                let family = profileFamily(nameSource)
                let materialType = inferType(profile: profile, family: family)
                let brand = normalizeBrand(profile: profile, family: family, folder: folder)
                let name = normalizeName(brand: brand, family: family, materialType: materialType, folder: folder)

                let sourceKey = [brand.lowercased(), materialType.lowercased(), name.lowercased(), filamentId]
                    .joined(separator: "|")
                guard records[sourceKey] == nil else { continue }

                let cfsCode = cfsMaterialCode(fromFilamentId: filamentId)
                let sourcePath = relativePath(of: fileURL, to: resourcesRoot)
                let rawJSON = rawJSONString(
                    profile: profile,
                    filamentId: filamentId,
                    profileFolder: folder,
                    sourcePath: sourcePath
                )

                records[sourceKey] = CrealityFilamentRecord(
                    sourceKey: sourceKey,
                    filamentId: filamentId,
                    brand: brand,
                    type: materialType,
                    name: name,
                    cfsMaterialCode: cfsCode.isEmpty ? nil : cfsCode,
                    sourcePath: sourcePath,
                    rawJSON: rawJSON
                )
            }
        }

        return records.values.sorted {
            ($0.brand, $0.type, $0.name, $0.filamentId) < ($1.brand, $1.type, $1.name, $1.filamentId)
        }
    }

    // MARK: - Field derivation (ports of the Python helpers of the same name)

    private static func profileFamily(_ name: String) -> String {
        let cleaned = cleanText(name)
        let beforeAt = cleaned.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? cleaned
        let trimmed = beforeAt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func inferType(profile: [String: Any], family: String) -> String {
        let filamentType = firstListValue(profile["filament_type"])
        if !filamentType.isEmpty { return filamentType.uppercased() }

        let inherits = cleanText(profile["inherits"])
        let haystack = "\(family) \(inherits)".uppercased()
        for material in knownMaterials {
            let escaped = NSRegularExpression.escapedPattern(for: material)
            let pattern = "(^|[^A-Z0-9])\(escaped)([^A-Z0-9]|$)"
            if haystack.range(of: pattern, options: .regularExpression) != nil {
                return material
            }
        }
        return "PLA"
    }

    private static func normalizeBrand(profile: [String: Any], family: String, folder: String) -> String {
        let vendor = firstListValue(profile["filament_vendor"])
        if family.uppercased().contains("GENERIC") { return "Generic" }
        let candidate = !vendor.isEmpty ? vendor : folder
        return candidate.isEmpty ? "Generic" : candidate
    }

    private static func normalizeName(brand: String, family: String, materialType: String, folder: String) -> String {
        var name = cleanText(family)
        if !folder.isEmpty {
            name = stripPrefix(name, prefix: folder)
        }
        name = stripPrefix(name, prefix: "generic")
        if !brand.isEmpty && brand.lowercased() != "generic" {
            name = stripPrefix(name, prefix: brand)
        }
        return name.isEmpty ? materialType : name
    }

    private static func cfsMaterialCode(fromFilamentId filamentId: String) -> String {
        guard filamentId.count == 5, filamentId.allSatisfy({ $0.isNumber }) else { return "" }
        return "0\(filamentId)"
    }

    // MARK: - Small string helpers

    /// Mirrors Python's `clean_text`: None/NSNull -> fallback, everything
    /// else -> its string form, trimmed.
    private static func cleanText(_ value: Any?, fallback: String = "") -> String {
        guard let value, !(value is NSNull) else { return fallback }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirrors Python's `first_list_value`: if the JSON value is an array,
    /// return the first non-empty cleaned entry; otherwise clean the scalar
    /// value directly.
    private static func firstListValue(_ value: Any?, fallback: String = "") -> String {
        if let array = value as? [Any] {
            for item in array {
                let text = cleanText(item)
                if !text.isEmpty { return text }
            }
            return fallback
        }
        return cleanText(value, fallback: fallback)
    }

    /// Strips a leading "<prefix> " (case-insensitive, whitespace-flexible)
    /// from `text`, mirroring the `re.sub(rf"^\s*{escaped}\s+", ...)` calls
    /// in the Python version.
    private static func stripPrefix(_ text: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: prefix)
        let pattern = "^\\s*\(escaped)\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func relativePath(of fileURL: URL, to root: URL) -> String {
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            var relative = String(filePath.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            return relative
        }
        return filePath
    }

    private static func rawJSONString(
        profile: [String: Any],
        filamentId: String,
        profileFolder: String,
        sourcePath: String
    ) -> String {
        func jsonValue(_ value: Any?) -> Any {
            guard let value, !(value is NSNull) else { return NSNull() }
            return value
        }
        let payload: [String: Any] = [
            "name": jsonValue(profile["name"]),
            "filament_id": filamentId,
            "filament_vendor": jsonValue(profile["filament_vendor"]),
            "filament_type": jsonValue(profile["filament_type"]),
            "inherits": jsonValue(profile["inherits"]),
            "profile_folder": profileFolder,
            "source_path": sourcePath,
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
