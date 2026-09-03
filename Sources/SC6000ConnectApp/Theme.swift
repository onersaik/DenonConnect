// Theme.swift
// Paleta de la app. Modo oscuro con los colores originales (negro puro);
// modo claro con paleta propia. Los colores de marca no cambian.

import SwiftUI
import AppKit

enum Theme {

    private static var dark: Bool { ThemeStore.isDarkGlobal }

    // ── Fondos ───────────────────────────────────────────────────────────────

    static var background: Color {
        dark ? Color.black
             : Color(red: 0.94, green: 0.94, blue: 0.95)
    }

    static var panel: Color {
        dark ? Color(red: 0.04, green: 0.04, blue: 0.045)
             : Color(red: 0.99, green: 0.99, blue: 1.00)
    }

    static var header: Color {
        dark ? Color.black
             : Color(red: 0.90, green: 0.90, blue: 0.92)
    }

    static var deckFill: Color {
        dark ? Color(red: 0.015, green: 0.015, blue: 0.018)
             : Color(red: 1.00, green: 1.00, blue: 1.00)
    }

    static var strip: Color {
        dark ? Color(red: 0.03, green: 0.03, blue: 0.035)
             : Color(red: 0.96, green: 0.96, blue: 0.97)
    }

    // ── Bordes y separadores ─────────────────────────────────────────────────

    static var panelBorder: Color {
        dark ? Color.white.opacity(0.08)
             : Color.black.opacity(0.12)
    }

    static var rowDivider: Color {
        dark ? Color(white: 0.12)
             : Color(white: 0.82)
    }

    // ── Texto ────────────────────────────────────────────────────────────────

    static var textPrimary: Color {
        dark ? Color.white
             : Color(red: 0.08, green: 0.08, blue: 0.10)
    }

    static var textSecondary: Color {
        dark ? Color.white.opacity(0.58)
             : Color.black.opacity(0.62)
    }

    static var textTertiary: Color {
        dark ? Color.white.opacity(0.34)
             : Color.black.opacity(0.38)
    }

    /// Velo neutro sobre el fondo: blanco en oscuro, negro en claro.
    static func overlay(_ o: Double) -> Color {
        dark ? Color.white.opacity(o) : Color.black.opacity(o)
    }

    /// Fondo de los botones sin estado activo
    static var buttonBg: Color {
        dark ? Color.white.opacity(0.07)
             : Color.black.opacity(0.07)
    }

    // ── Colores de marca (identicos en ambos modos) ──────────────────────────

    static let accent    = Color(red: 1.0,  green: 0.48, blue: 0.09)
    static let accentDim = Color(red: 1.0,  green: 0.48, blue: 0.09).opacity(0.35)

    static let green  = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let red    = Color(red: 0.95, green: 0.32, blue: 0.32)
    static let yellow = Color(red: 0.98, green: 0.78, blue: 0.30)
    static let purple = Color(red: 0.68, green: 0.55, blue: 0.98)
    static let cyan   = Color(red: 0.20, green: 0.78, blue: 0.95)

    static let ledGreen = Color(red: 0.38, green: 1.0, blue: 0.48)
    static let ledDim   = Color(red: 0.38, green: 1.0, blue: 0.48).opacity(0.22)

    static let wfBass = Color(red: 1.00, green: 0.32, blue: 0.06)
    static let wfMid  = Color(red: 0.78, green: 0.92, blue: 0.18)
    static let wfHigh = Color(red: 0.18, green: 0.42, blue: 1.00)

    // ── Acento por deck ──────────────────────────────────────────────────────

    static func deckAccent(_ index: Int) -> Color {
        switch index % 4 {
        case 0:  return Color(red: 1.0,  green: 0.48, blue: 0.09)
        case 1:  return Color(red: 0.20, green: 0.78, blue: 0.95)
        case 2:  return Color(red: 0.68, green: 0.55, blue: 0.98)
        default: return Color(red: 0.30, green: 0.85, blue: 0.50)
        }
    }
}

// MARK: - Modificadores

struct PanelBackground: ViewModifier {
    var cornerRadius: CGFloat = 4
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Theme.panelBorder, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func panelStyle(cornerRadius: CGFloat = 4) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Texto que nunca se parte ni se corta

extension View {
    /// Una sola linea, tamano natural: el boton crece con el texto en vez de partirlo.
    func noClip() -> some View {
        self.lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}
