// DeckLabelStore.swift
// Etiqueta visible de cada fila (letra, número o nombre). UserDefaults
// por id estable: denon token+layer, pioneer IP+player, TEST, Serato/VDJ.

import Foundation
import Combine

final class DeckLabelStore: ObservableObject {
    @Published private(set) var tags: [String: String] = [:]

    private static let defaultsKey = "sc.deckLabels.v1"

    init() {
        if let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] {
            tags = raw
        }
    }

    func tag(for key: String) -> String? {
        let t = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    func setTag(_ value: String, for key: String) {
        let t = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        let u = t.uppercased()
        if t.isEmpty || u == "TEST" || u == "SIM" {
            tags.removeValue(forKey: key)
        } else {
            tags[key] = t
        }
        persist()
    }

    func clear(_ key: String) {
        tags.removeValue(forKey: key)
        persist()
    }

    func clearAll() {
        tags.removeAll()
        persist()
    }

    var sortedKeys: [String] { tags.keys.sorted() }

    private func persist() {
        UserDefaults.standard.set(tags, forKey: Self.defaultsKey)
        objectWillChange.send()
    }
}

enum DeckLabelKey {
    static func denon(token: [UInt8], layer: Int) -> String {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        return "denon-\(hex)-L\(layer)"
    }

    static func pioneer(ip: String, player: Int) -> String {
        "pioneer-\(ip)-P\(player)"
    }

    static let pioneerTest = "pioneer-test"

    static func denonTest(_ layer: Int) -> String { "denon-test-\(layer)" }

    static func software(_ id: String) -> String { id }
}
