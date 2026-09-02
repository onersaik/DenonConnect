// Theme.swift
// Paleta de monitor DJ: negro profundo, dígitos LED, sin chrome gris de macOS.

import SwiftUI

enum Theme {
    /// Negro de escenario, no gris de ventana.
    static let background = Color.black
    static let panel = Color(red: 0.04, green: 0.04, blue: 0.045)
    static let header = Color.black
    static let deckFill = Color(red: 0.015, green: 0.015, blue: 0.018)
    static let strip = Color(red: 0.03, green: 0.03, blue: 0.035)
    static let panelBorder = Color.white.opacity(0.08)
    static let rowDivider = Color(white: 0.12)
    static let accent = Color(red: 1.0, green: 0.48, blue: 0.09)
    static let accentDim = Color(red: 1.0, green: 0.48, blue: 0.09).opacity(0.35)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.34)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let red = Color(red: 0.95, green: 0.32, blue: 0.32)
    static let yellow = Color(red: 0.98, green: 0.78, blue: 0.30)
    static let purple = Color(red: 0.68, green: 0.55, blue: 0.98)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 0.95)
    /// Verde Pioneer/CDJ para títulos y dígitos.
    static let ledGreen = Color(red: 0.38, green: 1.0, blue: 0.48)
    static let ledDim = Color(red: 0.38, green: 1.0, blue: 0.48).opacity(0.22)
    static let wfBass = Color(red: 0.95, green: 0.10, blue: 0.10)
    static let wfMid = Color(red: 0.12, green: 0.95, blue: 0.28)
    static let wfHigh = Color(red: 0.10, green: 0.88, blue: 1.0)

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
    var cornerRadius: CGFloat = 4
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
    func panelStyle(cornerRadius: CGFloat = 4) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}
