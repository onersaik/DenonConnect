// MusicalKey.swift
// Normaliza la tonalidad que llega por StageLinq, Pioneer o el nombre de pista.

import Foundation

public enum MusicalKey {
    /// Texto listo para UI. Vacío si no hay nada usable.
    public static func resolved(raw: String, title: String = "", artist: String = "") -> String {
        if let k = clean(raw) { return k }
        if let k = fromText(title) { return k }
        if let k = fromText(artist) { return k }
        return ""
    }

    public static func clean(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("Key:") { s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        let banned: Set<String> = ["", "-", "—", "–", "0", "none", "n/a", "na", "null", "unknown"]
        if banned.contains(s.lowercased()) { return nil }
        if let idx = Int(s), idx == 0 { return nil }
        if let fromIndex = fromIndex(Int(s) ?? -1), Int(s) != nil { return fromIndex }
        return s
    }

    public static func fromIndex(_ index: Int) -> String? {
        // Engine OS / rekordbox: 1...24 Camelot (1A...12A, 1B...12B). 0 = sin dato.
        guard index >= 1, index <= 24 else { return nil }
        if index <= 12 { return "\(index)A" }
        return "\(index - 12)B"
    }

    public static func fromText(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return nil }
        let camelot = try? NSRegularExpression(pattern: #"(?<![A-Z0-9])(1[0-2]|[1-9])\s*([ABab])(?![A-Z0-9])"#)
        if let camelot,
           let m = camelot.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let n = Range(m.range(at: 1), in: t),
           let l = Range(m.range(at: 2), in: t) {
            return "\(t[n])\(t[l].uppercased())"
        }
        let classical = try? NSRegularExpression(pattern: #"(?<![A-Z])([A-G](?:#|b)?)(m|min|maj|major)?(?![a-z])"#)
        if let classical,
           let m = classical.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let root = Range(m.range(at: 1), in: t) {
            var key = String(t[root])
            if m.range(at: 2).location != NSNotFound, let q = Range(m.range(at: 2), in: t) {
                let qual = t[q].lowercased()
                if qual == "m" || qual.hasPrefix("min") { key += "m" }
            }
            if key.count >= 1 { return key }
        }
        return nil
    }
}
