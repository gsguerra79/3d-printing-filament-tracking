//
//  UsageMath.swift
//  Creality K2 Filament Tracker and Inventory
//
//  Small pure-math helpers used by usage tracking: material-density-based
//  gram conversion, material-label matching, and color-distance scoring.
//  Direct port of the corresponding free functions in the original Python
//  app (density_for_material, diameter_to_mm, filament_mm_to_grams,
//  normalize_material_label, material_matches, color_distance).
//

import Foundation

enum MaterialDensity {
    static let gramsPerCC: [String: Double] = [
        "PLA": 1.24, "PETG": 1.27, "ABS": 1.04, "ASA": 1.07,
        "TPU": 1.20, "PC": 1.20, "NYLON": 1.14, "PA": 1.14,
    ]

    static func density(for material: String) -> Double {
        let text = material.uppercased()
        for (key, value) in gramsPerCC where text.contains(key) {
            return value
        }
        return 1.24
    }
}

enum UsageMath {
    static func diameterToMM(_ value: String) -> Double {
        let text = value.replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)
        return Double(text) ?? 1.75
    }

    static func filamentGrams(fromLengthMM length: Double, material: String, diameter: String = "1.75mm") -> Double {
        let diameterMM = diameterToMM(diameter)
        let areaMM2 = Double.pi * pow(diameterMM / 2, 2)
        let volumeCM3 = (max(0, length) * areaMM2) / 1000
        return volumeCM3 * MaterialDensity.density(for: material)
    }

    static func normalizeMaterialLabel(_ value: String) -> String {
        let uppercased = value.uppercased()
        let allowed = CharacterSet.uppercaseLetters.union(.decimalDigits)
        var result = ""
        var lastWasSeparator = true
        for scalar in uppercased.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append(" ")
                lastWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func materialMatches(_ left: String, _ right: String) -> Bool {
        let l = normalizeMaterialLabel(left)
        let r = normalizeMaterialLabel(right)
        guard !l.isEmpty, !r.isEmpty else { return false }
        if l.contains(r) || r.contains(l) { return true }
        return l.split(separator: " ").first == r.split(separator: " ").first
    }

    /// Sum of absolute per-channel differences between two "#rrggbb" colors.
    /// Lower is more similar; 0 is an exact match, ~765 is the maximum.
    static func colorDistance(_ left: String, _ right: String) -> Int {
        guard let l = rgb(left), let r = rgb(right) else { return 999 }
        return abs(l.0 - r.0) + abs(l.1 - r.1) + abs(l.2 - r.2)
    }

    private static func rgb(_ hex: String) -> (Int, Int, Int)? {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6,
              let r = Int(cleaned.prefix(2), radix: 16),
              let g = Int(cleaned.dropFirst(2).prefix(2), radix: 16),
              let b = Int(cleaned.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        return (r, g, b)
    }
}
