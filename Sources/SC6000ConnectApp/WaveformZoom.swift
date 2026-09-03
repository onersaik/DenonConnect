// WaveformZoom.swift
// Ventana visible del waveform CDJ. Más corta = más detalle; más larga = más contexto.

import SwiftUI

enum WaveformZoom {
    static let minSeconds: Double = 4
    static let maxSeconds: Double = 32
    static let defaultSeconds: Double = 12

    static func clamp(_ value: Double) -> Double {
        min(maxSeconds, max(minSeconds, value))
    }

    /// + / zoom in: menos segundos, más detalle alrededor de la aguja.
    static func zoomIn(_ current: Double) -> Double {
        clamp((current / 1.25).rounded())
    }

    /// − / zoom out: más segundos, más contexto de la pista.
    static func zoomOut(_ current: Double) -> Double {
        clamp((current * 1.25).rounded())
    }

    static func label(_ seconds: Double) -> String {
        "\(Int(clamp(seconds).rounded()))s"
    }
}

private struct WaveformWindowSecondsKey: EnvironmentKey {
    static let defaultValue: Double = WaveformZoom.defaultSeconds
}

extension EnvironmentValues {
    var waveformWindowSeconds: Double {
        get { self[WaveformWindowSecondsKey.self] }
        set { self[WaveformWindowSecondsKey.self] = newValue }
    }
}
