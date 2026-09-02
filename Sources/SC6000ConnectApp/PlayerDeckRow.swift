// PlayerDeckRow.swift
// Fila de deck: modo Grande (ShowKontrol) con tiempo LED en bloques + modo Pequeño compacto.

import SwiftUI
import AppKit
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
    let cuePositionFraction: Double?    // 0…1 cue activo; nil = sin cue
    let loopInFraction: Double?         // 0…1
    let loopOutFraction: Double?        // 0…1
    var artworkImage: NSImage? = nil   // portada del album (iTunes)

    var trackSeed: Int {
        var h = 0
        for c in title.unicodeScalars { h = h &* 31 &+ Int(c.value) }
        return abs(h)
    }
}

// MARK: - Fila principal

struct PlayerDeckRow: View {
    let deck: DeckDisplay
    var isLarge: Bool = true
    var isLTCSource: Bool = false
    var ltcAutoFollow: Bool = true
    var onSelectLTC: () -> Void = {}

    var body: some View {
        if isLarge { largeBody } else { smallBody }
    }

    // ═══════════════════════════════════════
    // MARK: Vista Grande (ShowKontrol style)
    // ═══════════════════════════════════════

    private var largeBody: some View {
        VStack(spacing: 0) {
            largeTopBar
            largeTrackAndTime
            WaveformView(
                progress:    deck.progress ?? 0,
                trackLength: deck.trackLength,
                bpm:         deck.bpm,
                beatInBar:   deck.beatInBar,
                isPlaying:   deck.isPlaying,
                accent:      deck.accent,
                trackSeed:   deck.trackSeed,
                cuePositionFraction: deck.cuePositionFraction,
                loopInFraction:  deck.loopInFraction,
                loopOutFraction: deck.loopOutFraction
            )
            .frame(height: 72)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .opacity(deck.loaded ? 1 : 0.30)
            largeBottomBar
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    deck.isPlaying ? deck.accent.opacity(0.55) : Color.white.opacity(0.07),
                    lineWidth: deck.isPlaying ? 1.5 : 1
                )
        )
    }

    private var largeTopBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(deck.isPlaying ? deck.accent : Theme.textTertiary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(deck.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundColor(Theme.textSecondary)

            if deck.isMaster { LEDTag(text: "MASTER", color: Theme.accent) }
            if deck.isOnAir  { LEDTag(text: "ON AIR", color: Theme.red) }
            if deck.isSynced { LEDTag(text: "SYNC",   color: Theme.cyan) }

            Spacer()

            ltcButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }

    private var largeTrackAndTime: some View {
        HStack(alignment: .top, spacing: 14) {

            // Título + artista + key + estado
            VStack(alignment: .leading, spacing: 4) {
                Text(deck.loaded ? (deck.title.isEmpty ? "—" : deck.title) : "SIN PISTA")
                    .font(.system(size: 17, weight: .semibold))
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

            // BPM + bloques de tiempo LED
            VStack(alignment: .trailing, spacing: 6) {
                // BPM con pitch
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    if let pitch = deck.pitchPercent, abs(pitch) > 0.01 {
                        Text(String(format: "%+.2f%%", pitch))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Theme.cyan)
                    }
                    Text(deck.bpm > 0 ? String(format: "%.2f", deck.bpm) : "---.--")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundColor(deck.bpm > 0 ? Theme.ledGreen : Theme.textTertiary.opacity(0.4))
                    Text("BPM")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                }

                // Bloques LED de tiempo
                ledTimeDisplay

                // Tiempo restante pequeño
                Text(remainingText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    /// MM : SS . CS en bloques con etiqueta arriba
    private var ledTimeDisplay: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ledBlock(value: timeField(deck.elapsed, .min), label: "MIN")
            ledSep(":")
            ledBlock(value: timeField(deck.elapsed, .sec), label: "SEG")
            ledSep(".")
            ledBlock(value: timeField(deck.elapsed, .cs),  label: "CS")
        }
    }

    private func ledBlock(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .tracking(0.4)
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary.opacity(0.25))
                .frame(width: 52, height: 36, alignment: .center)
                .background(Color.black.opacity(0.40))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func ledSep(_ char: String) -> some View {
        Text(char)
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundColor(deck.loaded ? Theme.ledGreen.opacity(0.35) : Theme.textTertiary.opacity(0.15))
            .padding(.bottom, 6)
    }

    private var largeBottomBar: some View {
        HStack(spacing: 10) {
            beatGrid(large: true)

            if !deck.key.isEmpty {
                Text(deck.key)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.purple)
            }

            Spacer()

            if let progress = deck.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [deck.accent.opacity(0.7), deck.accent],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: max(4, geo.size.width * progress))
                    }
                }
                .frame(width: 160, height: 5)

                Text(String(format: "%.0f%%", progress * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .padding(.top, 3)
    }

    // ═══════════════════════════════════════
    // MARK: Vista Pequeña (cuadrícula 2 col)
    // ═══════════════════════════════════════

    private var smallBody: some View {
        HStack(spacing: 10) {
            // Mini waveform
            WaveformView(
                progress:    deck.progress ?? 0,
                trackLength: deck.trackLength,
                bpm:         deck.bpm,
                beatInBar:   deck.beatInBar,
                isPlaying:   deck.isPlaying,
                accent:      deck.accent,
                trackSeed:   deck.trackSeed,
                cuePositionFraction: deck.cuePositionFraction,
                loopInFraction:  deck.loopInFraction,
                loopOutFraction: deck.loopOutFraction
            )
            .frame(width: 90, height: 44)
            .opacity(deck.loaded ? 1 : 0.30)

            // Info central
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(deck.isPlaying ? deck.accent : Theme.textTertiary.opacity(0.30))
                        .frame(width: 5, height: 5)
                    if deck.isMaster { LEDTag(text: "M",   color: Theme.accent) }
                    if deck.isOnAir  { LEDTag(text: "AIR", color: Theme.red) }
                    if isLTCSource   { LEDTag(text: "LTC", color: Theme.purple) }
                }
                Text(deck.loaded ? (deck.title.isEmpty ? "—" : deck.title) : "SIN PISTA")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary)
                    .lineLimit(1)
                if !deck.artist.isEmpty {
                    Text(deck.artist)
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Tiempo + BPM + botón LTC
            VStack(alignment: .trailing, spacing: 4) {
                Text(formatMS(deck.elapsed))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary.opacity(0.4))
                Text(deck.bpm > 0 ? String(format: "%.1f", deck.bpm) : "--.-")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                ltcButton
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.52)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    deck.isPlaying ? deck.accent.opacity(0.45) : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    // ═══════════════════════════════════════
    // MARK: Componentes compartidos
    // ═══════════════════════════════════════

    private var ltcButton: some View {
        Button(action: onSelectLTC) {
            HStack(spacing: 3) {
                if isLTCSource && ltcAutoFollow {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 7))
                }
                Text(isLTCSource ? "SMPTE ●" : "SMPTE")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.3)
            }
            .foregroundColor(isLTCSource ? .black : Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isLTCSource ? Theme.purple : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(isLTCSource ? "LTC fijado a este deck — pulsa para seguir al master" : "Fijar LTC a este deck")
    }

    private func beatGrid(large: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(1...4, id: \.self) { pos in
                RoundedRectangle(cornerRadius: 2)
                    .fill(beatColor(pos))
                    .frame(width: pos == 1 ? 9 : 6, height: large ? 18 : 12)
            }
        }
        .opacity(deck.isPlaying ? 1 : 0.30)
    }

    private func beatColor(_ pos: Int) -> Color {
        guard deck.beatInBar == pos else { return Color.white.opacity(0.10) }
        return pos == 1 ? Theme.accent : deck.accent
    }

    // MARK: Formateo de tiempo

    private enum TimeField { case min, sec, cs }

    private func timeField(_ s: Double?, _ f: TimeField) -> String {
        guard let s, s.isFinite, s >= 0 else { return "--" }
        switch f {
        case .min: return String(format: "%02d", Int(s) / 60)
        case .sec: return String(format: "%02d", Int(s) % 60)
        case .cs:  return String(format: "%02d", Int(s * 100) % 100)
        }
    }

    private func formatMS(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "--:--.--" }
        let cs = Int(s * 100) % 100
        let totalSec = Int(s)
        return String(format: "%02d:%02d.%02d", totalSec / 60, totalSec % 60, cs)
    }

    private var remainingText: String {
        guard let e = deck.elapsed, let l = deck.trackLength, l > 0 else { return "-  --:--.--" }
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
