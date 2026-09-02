// PlayerDeckRow.swift
// Fila estilo ShowKontrol: waveform scrolling, dígitos LED con milisegundos,
// BPM grande, beat 1-4, key, pitch %, barra de posición, tags MASTER/ON AIR/SYNC.
// Vista común para Denon (StageLinq) y Pioneer (Pro DJ Link).

import SwiftUI
import StageLinqKit

// MARK: - Modelo normalizado

struct DeckDisplay: Identifiable {
    enum Source { case denon, pioneer }

    let id: String
    let source: Source
    let label: String           // "SC6000 · DECK 1A", "CDJ-3000 · PLAYER 2"
    let title: String
    let artist: String
    let key: String
    let bpm: Double
    let pitchPercent: Double?
    let isPlaying: Bool
    let isMaster: Bool
    let isOnAir: Bool
    let isSynced: Bool
    let loaded: Bool
    let stateLabel: String
    let beatInBar: Int          // 1-4
    let beatPulse: Bool
    let elapsed: Double?        // segundos + fracción
    let trackLength: Double?
    let progress: Double?       // 0…1
    let accent: Color

    // Semilla determinista para el waveform (mismo track = misma forma)
    var trackSeed: Int {
        var h = 0
        for c in title.unicodeScalars { h = h &* 31 &+ Int(c.value) }
        return abs(h)
    }
}

// MARK: - Fila principal

struct PlayerDeckRow: View {
    let deck: DeckDisplay

    var body: some View {
        VStack(spacing: 0) {
            topBar
            trackInfo
            WaveformView(
                progress:    deck.progress ?? 0,
                trackLength: deck.trackLength,
                bpm:         deck.bpm,
                beatInBar:   deck.beatInBar,
                isPlaying:   deck.isPlaying,
                accent:      deck.accent,
                trackSeed:   deck.trackSeed
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .opacity(deck.loaded ? 1 : 0.35)
            bottomBar
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    deck.isPlaying ? deck.accent.opacity(0.55) : Color.white.opacity(0.07),
                    lineWidth: deck.isPlaying ? 1.5 : 1
                )
        )
    }

    // MARK: Barra superior: etiqueta + tags + BPM + tiempo

    private var topBar: some View {
        HStack(spacing: 10) {
            // ● indicador + nombre del deck
            HStack(spacing: 5) {
                Circle()
                    .fill(deck.isPlaying ? deck.accent : Theme.textTertiary.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(deck.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(Theme.textSecondary)
            }

            // Tags MASTER / ON AIR / SYNC
            if deck.isMaster { LEDTag(text: "MASTER", color: Theme.accent) }
            if deck.isOnAir  { LEDTag(text: "ON AIR", color: Theme.red) }
            if deck.isSynced { LEDTag(text: "SYNC",   color: Theme.cyan) }

            Spacer()

            // BPM grande a la derecha
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(deck.bpm > 0 ? String(format: "%.2f", deck.bpm) : "---.--")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(deck.bpm > 0 ? Theme.ledGreen : Theme.textTertiary.opacity(0.45))
                Text("BPM")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.textTertiary)
            }

            // Pitch %
            if let pitch = deck.pitchPercent {
                Text(String(format: "%+.2f%%", pitch))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(abs(pitch) > 0.01 ? Theme.cyan : Theme.textTertiary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Título + artista + tiempo LED

    private var trackInfo: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(deck.loaded ? (deck.title.isEmpty ? "—" : deck.title) : "SIN PISTA")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if !deck.artist.isEmpty {
                        Text(deck.artist)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    if !deck.key.isEmpty {
                        Text(deck.key)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.purple)
                    }
                    Text(deck.stateLabel.uppercased())
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            Spacer()

            // Columna de tiempos con milisegundos
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatMS(deck.elapsed))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary.opacity(0.45))

                Text(remainingText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: Barra inferior: beat grid + key + barra progreso

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Rejilla de beats 1-4
            beatGrid

            if !deck.key.isEmpty {
                Text(deck.key)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.purple)
            }

            Spacer()

            // Barra de progreso
            if let progress = deck.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [deck.accent.opacity(0.7), deck.accent],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, geo.size.width * progress))
                    }
                }
                .frame(width: 160, height: 5)

                Text(String(format: "%.0f%%", (deck.progress ?? 0) * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    // MARK: Beat grid

    private var beatGrid: some View {
        HStack(spacing: 3) {
            ForEach(1...4, id: \.self) { pos in
                RoundedRectangle(cornerRadius: 2)
                    .fill(beatColor(pos))
                    .frame(width: pos == 1 ? 9 : 6, height: 18)
            }
        }
        .opacity(deck.isPlaying ? 1 : 0.30)
    }

    private func beatColor(_ pos: Int) -> Color {
        guard deck.beatInBar == pos else { return Color.white.opacity(0.10) }
        return pos == 1 ? Theme.accent : deck.accent
    }

    // MARK: Formateo de tiempo con milisegundos (MM:SS.mm)

    private func formatMS(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "--:--.--" }
        let totalMs  = Int(s * 100)       // centésimas
        let cs       = totalMs % 100
        let totalSec = totalMs / 100
        let secs     = totalSec % 60
        let mins     = totalSec / 60
        return String(format: "%02d:%02d.%02d", mins, secs, cs)
    }

    private var remainingText: String {
        guard let e = deck.elapsed, let l = deck.trackLength, l > 0 else { return "--:--.--" }
        return "-" + formatMS(max(l - e, 0))
    }
}

// MARK: - Componentes compartidos

struct LEDTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.4)
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.16)))
    }
}
