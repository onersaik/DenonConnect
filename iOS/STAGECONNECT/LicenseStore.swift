// LicenseStore.swift
// Activación local: mensual (entikmedia, 30 días) o vitalicia (laif).
// Se puede revocar desde CONFIG.

import Foundation
import Combine

enum LicenseKind: String {
    case monthly
    case lifetime
}

final class LicenseStore: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var kind: LicenseKind?
    @Published private(set) var expiresAt: Date?
    @Published var lastError: String = ""

    private let defaults = UserDefaults.standard
    private let kindKey = "stageconnect.license.kind"
    private let dateKey = "stageconnect.license.activatedAt"

    private static let monthlyCode = "entikmedia"
    private static let lifetimeCode = "laif"
    private static let monthSeconds: TimeInterval = 30 * 24 * 60 * 60

    init() {
        refresh()
    }

    func refresh() {
        lastError = ""
        guard let raw = defaults.string(forKey: kindKey),
              let stored = LicenseKind(rawValue: raw) else {
            isUnlocked = false
            kind = nil
            expiresAt = nil
            return
        }
        let activated = Date(timeIntervalSince1970: defaults.double(forKey: dateKey))
        switch stored {
        case .lifetime:
            kind = .lifetime
            expiresAt = nil
            isUnlocked = true
        case .monthly:
            let end = activated.addingTimeInterval(Self.monthSeconds)
            kind = .monthly
            expiresAt = end
            isUnlocked = Date() < end
            if !isUnlocked {
                clearStored()
                kind = nil
                expiresAt = nil
            }
        }
    }

    @discardableResult
    func activate(code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lastError = ""
        if trimmed == Self.lifetimeCode {
            persist(.lifetime)
            return true
        }
        if trimmed == Self.monthlyCode {
            persist(.monthly)
            return true
        }
        lastError = "Clave no válida."
        return false
    }

    func deactivate() {
        clearStored()
        isUnlocked = false
        kind = nil
        expiresAt = nil
        lastError = ""
    }

    var statusText: String {
        switch kind {
        case .lifetime:
            return "Licencia vitalicia"
        case .monthly:
            if let end = expiresAt {
                let f = DateFormatter()
                f.locale = Locale(identifier: "es")
                f.dateStyle = .medium
                f.timeStyle = .none
                return "Licencia de un mes · caduca \(f.string(from: end))"
            }
            return "Licencia de un mes"
        case nil:
            return "Sin licencia"
        }
    }

    private func persist(_ kind: LicenseKind) {
        defaults.set(kind.rawValue, forKey: kindKey)
        defaults.set(Date().timeIntervalSince1970, forKey: dateKey)
        refresh()
    }

    private func clearStored() {
        defaults.removeObject(forKey: kindKey)
        defaults.removeObject(forKey: dateKey)
    }
}
