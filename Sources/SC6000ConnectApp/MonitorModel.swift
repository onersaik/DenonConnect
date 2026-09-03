// MonitorModel.swift
// Vistas, tamaños y paleta de la ventana MONITOR (segunda pantalla / overlay).

import SwiftUI
import AppKit

enum MonitorLayout: String, CaseIterable, Identifiable {
    case soloTC = "Solo TC"
    case datos = "Solo datos"
    case cdj = "CDJ"
    case overview = "Overview"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .soloTC: return "Solo el timecode, lo mas grande posible. Negro a sangre. Ideal cabina / overlay."
        case .datos: return "MASTER + TC + decks. Sin chrome en pantalla completa."
        case .cdj: return "Aguja al centro, zoom de pista, MASTER grande."
        case .overview: return "Pista entera por fila. Contexto de todo el set."
        }
    }

    var isPresentation: Bool {
        self == .soloTC || self == .datos
    }

    static func resolved(_ raw: String) -> MonitorLayout {
        if let match = MonitorLayout(rawValue: raw) { return match }
        if raw == "TC" || raw == "Master" { return .soloTC }
        if raw == "Todos" || raw == "TC + decks" || raw == "Mini" { return .datos }
        return .datos
    }
}

enum MonitorSizePreset: String, CaseIterable, Identifiable {
    case cabina = "Cabina"
    case hd = "1080p"
    case mini = "Mini"

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .cabina: return CGSize(width: 1280, height: 720)
        case .hd: return CGSize(width: 1920, height: 1080)
        case .mini: return CGSize(width: 720, height: 420)
        }
    }

    var help: String {
        switch self {
        case .cabina: return "1280×720, cabina / projector."
        case .hd: return "1920×1080."
        case .mini: return "720×420, esquina de pantalla."
        }
    }
}

struct MonitorPalette {
    let background: Color
    let panel: Color
    let strip: Color
    let deckFill: Color
    let text: Color
    let textSecondary: Color
    let textTertiary: Color
    let ledGreen: Color
    let ledOrange: Color
    let ledYellow: Color
    let ledDim: Color
    let divider: Color
    let waveformBG: Color
    let playhead: Color
    let controlFill: Color
    let controlOn: Color
    let controlOnText: Color

    static let night = MonitorPalette(
        background: Color.black,
        panel: Color(red: 0.04, green: 0.04, blue: 0.045),
        strip: Color(red: 0.03, green: 0.03, blue: 0.035),
        deckFill: Color(red: 0.015, green: 0.015, blue: 0.018),
        text: Color.white,
        textSecondary: Color.white.opacity(0.58),
        textTertiary: Color.white.opacity(0.34),
        ledGreen: Theme.ledGreen,
        ledOrange: Theme.accent,
        ledYellow: Theme.yellow,
        ledDim: Theme.ledDim,
        divider: Color.white.opacity(0.10),
        waveformBG: Color.black,
        playhead: Color.white,
        controlFill: Color.white.opacity(0.08),
        controlOn: Theme.accent,
        controlOnText: Color.black
    )

    /// Ensayo de día: fondo claro, texto oscuro, LED naranja/verde legibles.
    static let day = MonitorPalette(
        background: Color(red: 0.93, green: 0.92, blue: 0.88),
        panel: Color(red: 0.97, green: 0.96, blue: 0.93),
        strip: Color(red: 0.90, green: 0.89, blue: 0.84),
        deckFill: Color(red: 0.88, green: 0.87, blue: 0.82),
        text: Color(red: 0.10, green: 0.10, blue: 0.11),
        textSecondary: Color(red: 0.28, green: 0.27, blue: 0.24),
        textTertiary: Color(red: 0.46, green: 0.44, blue: 0.40),
        ledGreen: Color(red: 0.06, green: 0.48, blue: 0.20),
        ledOrange: Color(red: 0.82, green: 0.36, blue: 0.04),
        ledYellow: Color(red: 0.72, green: 0.46, blue: 0.02),
        ledDim: Color(red: 0.06, green: 0.48, blue: 0.20).opacity(0.28),
        divider: Color.black.opacity(0.12),
        waveformBG: Color(red: 0.98, green: 0.97, blue: 0.94),
        playhead: Color(red: 0.08, green: 0.08, blue: 0.09),
        controlFill: Color.black.opacity(0.07),
        controlOn: Color(red: 0.82, green: 0.36, blue: 0.04),
        controlOnText: Color.white
    )

    static func resolve(day: Bool) -> MonitorPalette { day ? .day : .night }
}

/// Chrome de la ventana MONITOR / SETLIST: tamaño, overlay, pantalla completa.
struct MonitorWindowChrome: NSViewRepresentable {
    var dayMode: Bool
    var opacity: Double
    var alwaysOnTop: Bool
    var sizeToken: String
    var targetSize: CGSize
    var wantsFullscreen: Bool = false
    var chromeHidden: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(nsView.window, coordinator: context.coordinator)
    }

    final class Coordinator {
        var lastSizeToken = ""
        var lastFullscreen: Bool?
    }

    private func apply(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 640, height: 360)
        let presentation = chromeHidden || wantsFullscreen
        window.backgroundColor = (dayMode && !presentation)
            ? NSColor(calibratedWhite: 0.93, alpha: 1)
            : NSColor.black
        let alpha = min(1, max(0.35, opacity))
        window.alphaValue = CGFloat(alpha)
        window.isOpaque = alpha >= 0.98
        window.level = (alwaysOnTop && !wantsFullscreen) ? .floating : .normal
        window.hasShadow = !wantsFullscreen
        if coordinator.lastFullscreen != wantsFullscreen {
            coordinator.lastFullscreen = wantsFullscreen
            let isFS = window.styleMask.contains(.fullScreen)
            if wantsFullscreen != isFS {
                window.toggleFullScreen(nil)
            }
        }
        if coordinator.lastSizeToken != sizeToken, !wantsFullscreen {
            coordinator.lastSizeToken = sizeToken
            var frame = window.frame
            let screen = window.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 900)
            let w = min(targetSize.width, visible.width)
            let h = min(targetSize.height, visible.height)
            frame.size = NSSize(width: w, height: h)
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
