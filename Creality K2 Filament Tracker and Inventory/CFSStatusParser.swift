//
//  CFSStatusParser.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Parses the raw JSON Moonraker sends for the K2 Plus's CFS ("box") object
//  and the external spool holder ("filament_rack") object. This is a direct
//  port of extract_slots()/normalize_color()/color_name_for_hex()/
//  normalize_external_slot() from the original Python app, scoped to the
//  one box shape that printer actually reports (T1..T4 trays, each with
//  four lettered sub-slots) rather than the several speculative fallback
//  shapes the Python version probed for.
//

import Foundation

/// A single occupied filament position reported by the printer — either a
/// CFS tray slot or the external spool holder.
struct ParsedCFSSlot {
    var slotName: String
    /// Global 0-based index across all CFS tray sub-slots (T1A = 0, T1B = 1,
    /// ... T2A = 4, etc). Only slots whose index falls within the app's
    /// configured "CFS Slot N" locations actually get synced — see
    /// SpoolRepository.syncPrinterSlots. `nil` for the external holder.
    var slotIndex: Int?
    /// Set only for the external holder, whose location is matched by name
    /// instead of by index.
    var locationName: String?
    var brand: String
    var material: String
    var colorName: String
    var colorHex: String
    var cfsMaterialCode: String
    var cfsColorCode: String
    var remainingWeightG: Int
    var originalWeightG: Int
}

enum StandardColors {
    static let options: [(name: String, hex: String)] = [
        ("Black", "#000000"), ("White", "#ffffff"), ("Gray", "#808080"),
        ("Silver", "#c0c0c0"), ("Red", "#ff0000"), ("Orange", "#ff7a00"),
        ("Yellow", "#ffd400"), ("Green", "#00a650"), ("Blue", "#006fd6"),
        ("Purple", "#7a3db8"), ("Pink", "#ff6bb5"), ("Brown", "#7a4a2a"),
        ("Beige", "#d8c3a5"), ("Gold", "#cf942b"), ("Natural", "#f2ead8"),
        ("Clear", "#f7f7f7"), ("Wood", "#d8b589"),
    ]
}

enum CFSStatusParser {
    static func normalizeColor(_ value: Any?) -> String {
        if let text = value as? String {
            let color = text.trimmingCharacters(in: .whitespaces)
            let isHexDigits = color.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
            if color.count == 6, isHexDigits {
                return "#" + color
            }
            if color.count == 7, isHexDigits {
                return "#" + String(color.suffix(6))
            }
            if color.count == 7, color.hasPrefix("#") {
                return color
            }
            if color.count == 8, color.hasPrefix("#") {
                return "#" + String(color.suffix(6))
            }
        }
        if let array = value as? [Any], array.count >= 3 {
            let r = intValue(array[0], fallback: 128)
            let g = intValue(array[1], fallback: 128)
            let b = intValue(array[2], fallback: 128)
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        return "#888888"
    }

    static func colorName(forHex hex: String) -> String {
        let normalized = normalizeColor(hex).lowercased()
        if let match = StandardColors.options.first(where: { $0.hex.lowercased() == normalized }) {
            return match.name
        }
        guard let (r, g, b) = rgb(from: normalized) else { return "Gray" }
        var best = StandardColors.options[0]
        var bestDistance = Int.max
        for option in StandardColors.options {
            guard let (or, og, ob) = rgb(from: option.hex) else { continue }
            let distance = (r - or) * (r - or) + (g - og) * (g - og) + (b - ob) * (b - ob)
            if distance < bestDistance {
                bestDistance = distance
                best = option
            }
        }
        return best.name
    }

    private static func rgb(from hex: String) -> (Int, Int, Int)? {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6 else { return nil }
        guard
            let r = Int(cleaned.prefix(2), radix: 16),
            let g = Int(cleaned.dropFirst(2).prefix(2), radix: 16),
            let b = Int(cleaned.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        return (r, g, b)
    }

    private static func intValue(_ value: Any?, fallback: Int) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let s = value as? String, let n = Int(s) { return n }
        return fallback
    }

    /// Parses the K2 Plus CFS "box" status object. Mirrors extract_slots()'s
    /// T1-T4 branch: each tray (T1..T4) has parallel arrays for its four
    /// lettered sub-slots (A-D), plus a "same_material" lookup table Creality
    /// uses to report RFID-identified spools by code.
    static func parseCFSBox(_ value: [String: Any]) -> [ParsedCFSSlot] {
        guard ["T1", "T2", "T3", "T4"].contains(where: { value[$0] != nil }) else {
            return []
        }

        struct MaterialInfo {
            var material: String
            var colorHex: String
            var cfsMaterialCode: String
            var cfsColorCode: String
        }

        var materialLookup: [String: MaterialInfo] = [:]
        if let sameMaterial = value["same_material"] as? [[Any]] {
            for item in sameMaterial where item.count >= 4 {
                let code = String(describing: item[0])
                let color = String(describing: item[1])
                let material = String(describing: item[3])
                let info = MaterialInfo(
                    material: material,
                    colorHex: normalizeColor(color),
                    cfsMaterialCode: code,
                    cfsColorCode: color
                )
                if let slotNames = item[2] as? [Any] {
                    for slotName in slotNames {
                        materialLookup[String(describing: slotName)] = info
                    }
                }
                materialLookup[code] = info
            }
        }

        var slots: [ParsedCFSSlot] = []
        for trayIndex in 1...4 {
            let trayName = "T\(trayIndex)"
            guard
                let tray = value[trayName] as? [String: Any],
                (tray["state"] as? String) == "connect"
            else { continue }

            let colors = tray["color_value"] as? [Any] ?? []
            let materials = tray["material_type"] as? [Any] ?? []
            let remaining = tray["remain_len"] as? [Any] ?? []
            let vendors = tray["vender"] as? [Any] ?? []

            for (letterIndex, letter) in ["A", "B", "C", "D"].enumerated() {
                let slotName = "\(trayName)\(letter)"
                let color = letterIndex < colors.count ? String(describing: colors[letterIndex]) : "-1"
                let materialCode = letterIndex < materials.count ? String(describing: materials[letterIndex]) : "-1"
                let remain = letterIndex < remaining.count ? remaining[letterIndex] : "100"
                let vendor = letterIndex < vendors.count ? String(describing: vendors[letterIndex]) : ""

                if color == "-1" || materialCode == "-1" { continue }

                let mapped = materialLookup[slotName] ?? materialLookup[materialCode]
                let material = mapped?.material ?? materialCode
                let percent = intValue(remain, fallback: 100)

                slots.append(
                    ParsedCFSSlot(
                        slotName: slotName,
                        slotIndex: (trayIndex - 1) * 4 + letterIndex,
                        locationName: nil,
                        brand: (!vendor.isEmpty && vendor.lowercased() != "unknown") ? "Creality RFID" : "CFS",
                        material: material,
                        colorName: "\(slotName) \(material)",
                        colorHex: normalizeColor(mapped?.colorHex ?? color),
                        cfsMaterialCode: mapped?.cfsMaterialCode ?? materialCode,
                        cfsColorCode: mapped?.cfsColorCode ?? color,
                        remainingWeightG: min(1000, percent * 10),
                        originalWeightG: 1000
                    )
                )
            }
        }
        return slots
    }

    /// Mirrors normalize_external_slot() for the external spool holder.
    static func parseExternalSlot(_ value: [String: Any]) -> ParsedCFSSlot? {
        let materialCode = String(describing: value["material_type"] ?? "").trimmingCharacters(in: .whitespaces)
        let colorCode = String(describing: value["color_value"] ?? "").trimmingCharacters(in: .whitespaces)
        guard materialCode != "", materialCode != "-1", colorCode != "", colorCode != "-1" else {
            return nil
        }
        let colorHex = normalizeColor(colorCode)
        return ParsedCFSSlot(
            slotName: "External",
            slotIndex: nil,
            locationName: "External Spool Holder",
            brand: "External Spool Holder",
            material: materialCode,
            colorName: colorName(forHex: colorHex),
            colorHex: colorHex,
            cfsMaterialCode: materialCode,
            cfsColorCode: colorCode,
            remainingWeightG: 1000,
            originalWeightG: 1000
        )
    }
}
