//
//  UsageSnapshotParser.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Turns the raw Moonraker status (print_stats + virtual_sdcard + box) into
//  a PrintUsageSnapshot describing the current/last print: how much
//  filament it has used so far, how confident that estimate is (slicer
//  estimate vs. progress vs. raw extrusion length), and — for multicolor
//  prints — how that usage splits across colors/parts. Direct port of
//  fetch_printer_usage_snapshot() from the original Python app.
//

import Foundation

struct UsagePart {
    var index: Int
    var plannedGrams: Double
    var material: String
    var colorHex: String
}

struct PrintUsageSnapshot {
    var filename: String
    var signature: String
    var state: String
    var progress: Double
    var material: String
    var plannedTotalGrams: Double
    var usedGrams: Double
    var filamentUsedMM: Double
    var basis: String
    var parts: [UsagePart]
    var activeCFSSlotName: String
    /// Diagnostic only (2026-08-22): whether the merged Moonraker status had
    /// a "print_stats"/"virtual_sdcard" key at all, distinct from that key
    /// being present but empty. Helps tell "this printer's firmware doesn't
    /// expose these objects the way stock Klipper does" apart from "it does,
    /// but there's genuinely no print running right now."
    var hasPrintStatsKey: Bool = false
    var hasVirtualSDCardKey: Bool = false
}

enum UsageSnapshotParser {
    /// `status` is the combined Moonraker status dict, expected to (possibly)
    /// contain "box", "print_stats", and "virtual_sdcard" keys.
    static func parse(_ status: [String: Any]) -> PrintUsageSnapshot {
        let printStats = status["print_stats"] as? [String: Any] ?? [:]
        let virtualSDCard = status["virtual_sdcard"] as? [String: Any] ?? [:]
        let box = status["box"] as? [String: Any] ?? [:]
        let currentPrint = virtualSDCard["cur_print_data"] as? [String: Any] ?? [:]
        let metadata = currentPrint["metadata"] as? [String: Any] ?? [:]
        let modelInfo = metadata["model_info"] as? [String: Any] ?? [:]

        let filename = string(printStats["filename"])
            .orIfEmpty(string(currentPrint["filename"]))
            .orIfEmpty((string(virtualSDCard["file_path"]) as NSString).lastPathComponent)

        let currentPrintStatus = string(currentPrint["status"])
        let terminalStates: Set<String> = ["completed", "cancelled", "error"]
        let state = terminalStates.contains(currentPrintStatus)
            ? currentPrintStatus
            : string(printStats["state"]).orIfEmpty(currentPrintStatus)

        let startTime = string(currentPrint["start_time"]).orIfEmpty(string(metadata["uuid"]))

        let rawMaterial = string(metadata["filament_type"])
            .orIfEmpty(string(modelInfo["MaterialType"]))
            .orIfEmpty(string(printStats["filament_type"]))
        let material = rawMaterial.uppercased()
        let materialValues = material
            .components(separatedBy: CharacterSet(charactersIn: ";,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var progress = double(virtualSDCard["progress"])
        progress = max(0, min(progress, 1))

        let plannedGrams = (metadata["filament_used_g"] as? [Any] ?? []).map { max(0, double($0)) }
        let plannedTotalGrams = plannedGrams.reduce(0, +)

        let filamentUsedMM = double(printStats["filament_used"] ?? currentPrint["filament_used"])

        let usedGrams: Double
        let basis: String
        if plannedTotalGrams > 0, state == "completed" {
            usedGrams = plannedTotalGrams
            basis = "completed slicer estimate"
        } else if plannedTotalGrams > 0, progress > 0 {
            usedGrams = plannedTotalGrams * progress
            basis = "slicer progress"
        } else {
            usedGrams = UsageMath.filamentGrams(fromLengthMM: filamentUsedMM, material: material.isEmpty ? "PLA" : material)
            basis = "extrusion length"
        }

        let colors = metadata["default_filament_colour"] as? [Any] ?? []
        var parts: [UsagePart] = []
        for (index, grams) in plannedGrams.enumerated() where grams > 0 {
            let partMaterial = index < materialValues.count ? materialValues[index] : material
            let colorHex: String
            if index < colors.count, let colorValue = colors[index] as? String, !colorValue.isEmpty {
                colorHex = CFSStatusParser.normalizeColor(colorValue)
            } else {
                colorHex = ""
            }
            parts.append(UsagePart(index: index, plannedGrams: grams, material: partMaterial, colorHex: colorHex))
        }
        if parts.isEmpty {
            parts = [UsagePart(index: 0, plannedGrams: max(plannedTotalGrams, 1), material: material, colorHex: "")]
        }

        let signature = filename.isEmpty ? "" : "\(filename)|\(startTime)"

        return PrintUsageSnapshot(
            filename: filename,
            signature: signature,
            state: state,
            progress: progress,
            material: material,
            plannedTotalGrams: plannedTotalGrams,
            usedGrams: max(0, usedGrams),
            filamentUsedMM: filamentUsedMM,
            basis: basis,
            parts: parts,
            activeCFSSlotName: activeCFSSlotName(fromBox: box),
            hasPrintStatsKey: status["print_stats"] != nil,
            hasVirtualSDCardKey: status["virtual_sdcard"] != nil
        )
    }

    /// Mirrors active_cfs_slot_name_from_box(): finds whichever tray is
    /// physically feeding the hotend right now.
    static func activeCFSSlotName(fromBox box: [String: Any]) -> String {
        for trayIndex in 1...4 {
            let trayName = "T\(trayIndex)"
            guard
                let tray = box[trayName] as? [String: Any],
                (tray["state"] as? String) == "connect"
            else { continue }
            let filament = string(tray["filament"]).uppercased()
            if ["A", "B", "C", "D"].contains(filament) {
                return "\(trayName)\(filament)"
            }
        }
        if let filamentIndex = box["filament"] as? Int, (0...3).contains(filamentIndex) {
            let letters = ["A", "B", "C", "D"]
            return "T1\(letters[filamentIndex])"
        }
        return ""
    }

    /// Mirrors cfs_location_name_for_slot(): "T1A" -> "CFS Slot 1", "T2C" -> "CFS Slot 7", etc.
    static func cfsLocationName(forSlotName slotName: String) -> String? {
        let upper = slotName.uppercased()
        guard upper.count >= 2, upper.first == "T" else { return nil }
        let letterPart = String(upper.suffix(1))
        let trayPart = String(upper.dropFirst().dropLast())
        guard
            let trayIndex = Int(trayPart),
            let letterIndex = ["A", "B", "C", "D"].firstIndex(of: letterPart)
        else { return nil }
        return "CFS Slot \((trayIndex - 1) * 4 + letterIndex + 1)"
    }

    private static func string(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        return String(describing: value)
    }

    private static func double(_ value: Any?) -> Double {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String, let n = Double(s) { return n }
        return 0
    }
}

private extension String {
    func orIfEmpty(_ fallback: @autoclosure () -> String) -> String {
        isEmpty ? fallback() : self
    }
}
