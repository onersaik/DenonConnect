// Theme.swift
// Paleta visual coherente con el icono de la app (carbón oscuro + acento naranja).

import SwiftUI

enum Theme {
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.12)
    static let panelBorder = Color.white.opacity(0.08)
    static let accent = Color(red: 1.0, green: 0.48, blue: 0.09) // naranja Denon-esque
    static let accentDim = Color(red: 1.0, green: 0.48, blue: 0.09).opacity(0.35)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
    static let textTertiary = Color.white.opacity(0.38)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let red = Color(red: 0.95, green: 0.32, blue: 0.32)
    static let yellow = Color(red: 0.98, green: 0.78, blue: 0.30)
    static let purple = Color(red: 0.68, green: 0.55, blue: 0.98)
    static let cyan = Color(red: 0.35, green: 0.82, blue: 0.90)
    /// Verde de display de reproductor, para los dígitos LED.
    static let ledGreen = Color(red: 0.42, green: 1.0, blue: 0.55)

    static func deckAccent(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case 1: return Color(red: 0.20, green: 0.75, blue: 0.55)
        case 2: return Color(red: 0.95, green: 0.55, blue: 0.15)
        default: return Color(red: 0.68, green: 0.35, blue: 0.90)
        }
    }
}

struct PanelBackground: ViewModifier {
    var cornerRadius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.panelBorder, lineWidth: 1)
            )
    }
}

extension View {
    func panelStyle(cornerRadius: CGFloat = 14) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}
