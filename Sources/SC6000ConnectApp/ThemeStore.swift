// ThemeStore.swift
// Preferencia de apariencia (oscuro / claro) persistente.

import SwiftUI

final class ThemeStore: ObservableObject {
    /// Espejo estatico para que Theme pueda leer el modo sin environment.
    /// Se actualiza en cada cambio; el preferredColorScheme fuerza el redibujado.
    static private(set) var isDarkGlobal: Bool = {
        UserDefaults.standard.object(forKey: "sc.isDark") as? Bool ?? true
    }()

    @Published var isDark: Bool {
        didSet {
            UserDefaults.standard.set(isDark, forKey: "sc.isDark")
            ThemeStore.isDarkGlobal = isDark
        }
    }

    init() {
        let v = UserDefaults.standard.object(forKey: "sc.isDark") as? Bool ?? true
        self.isDark = v
        ThemeStore.isDarkGlobal = v
    }

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    func toggle() { isDark.toggle() }
}
