// PlayerDeckRow.swift
// Fila de deck: Grande (monitor tipo ShowKontrol) y Pequeña (mosaico 2 col).

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
    var peaks: [Float] = []             // waveform real (TEST); vacío = procedural
    var artworkImage: NSImage? = nil

    var trackSeed: Int {
        if !title.isEmpty {
            var h = 0
            for c in title.unicodeScalars { h = h &* 31 &+ Int(c.value) }
            return abs(h)
        }
        var h = 0
        for c in id.unicodeScalars { h = h &* 31 &+ Int(c.value) }
        return abs(h)
    }

    var kindLabel: String { source == .denon ? "DECK" : "PLAYER" }

    /// Identificador corto para la tira izquierda (A/B o número de player).
    var deckTag: String {
        let last = label.split(separator: " ").last.map(String.init) ?? ""
        if last.count <= 2 { return last.uppercased() }
        return source == .pioneer ? "1" : "A"
    }
}

// MARK: - Fila principal

struct PlayerDeckRow: View {
    let deck: DeckDisplay
    var isLarge: Bool = true
    var isLTCSource: Bool = false
    var isHot: Bool = false
    var ltcAutoFollow: Bool = true
    var onSelectLTC: () -> Void = {}

    var body: some View {
        Group {
            if isLarge { largeBody } else { smallBody }
        }
        .transaction { $0.animation = nil }
    }

    // ═══════════════════════════════════════
    // MARK: Vista Grande (monitor DJ)
    // ═══════════════════════════════════════

    private var largeBody: some View {
        HStack(alignment: .top, spacing: 0) {
            deckIndexStrip

            VStack(spacing: 0) {
                largeMetaRow
                WaveformView(
                    progress:    deck.progress,
                    trackLength: deck.trackLength,
                    bpm:         deck.bpm,
                    beatInBar:   deck.beatInBar,
                    isPlaying:   deck.isPlaying,
                    accent:      deck.accent,
                    trackSeed:   deck.trackSeed,
                    peaks: deck.peaks,
                    cuePositionFraction: deck.cuePositionFraction,
                    loopInFraction:  deck.loopInFraction,
                    loopOutFraction: deck.loopOutFraction,
                    mode: .scrolling,
                    windowSeconds: 12
                )
                .id(deck.id)
                .frame(height: 92)
                .opacity(deck.loaded && (deck.progress != nil || !deck.peaks.isEmpty) ? 1 : 0.28)
                .transaction { $0.animation = nil }
                largeBottomBar
            }
        }
        .background(Theme.deckFill)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(deck.isPlaying ? deck.accent : Color.clear)
                .frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowDivider).frame(height: 1)
        }
    }

    private var deckIndexStrip: some View {
        VStack(spacing: 5) {
            Text(deck.kindLabel)
                .font(.system(size: 7, weight: .bold))
                .tracking(1.1)
                .foregroundColor(Theme.textTertiary)

            Text(deck.deckTag)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 34, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(deck.isPlaying ? deck.accent : Theme.rowDivider, lineWidth: 1)
                )

            Image(systemName: deck.isPlaying ? "play.fill" : "pause.fill")
                .font(.system(size: 8))
                .foregroundColor(deck.isPlaying ? Theme.ledGreen : Theme.textTertiary)

            if deck.isMaster { LEDTag(text: "MST", color: Theme.accent) }
            if deck.isOnAir  { LEDTag(text: "AIR", color: Theme.red) }
            if deck.isSynced { LEDTag(text: "SYNC", color: Theme.cyan) }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: 50)
        .frame(maxHeight: .infinity)
        .background(Theme.strip)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.rowDivider).frame(width: 1)
        }
    }

    private var largeMetaRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

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
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(Theme.textTertiary)
                    Text(deck.label.uppercased())
                        .font(.system(size: 8, weight: .medium))
                        .tracking(0.4)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ledTimeDisplay

            VStack(alignment: .trailing, spacing: 1) {
                if let pitch = deck.pitchPercent, abs(pitch) > 0.01 {
                    Text(String(format: "%+.2f%%", pitch))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.cyan)
                }
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(bpmText)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(deck.bpm > 0 ? Theme.ledGreen : Theme.ledDim)
                    Text("BPM")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// MM : SS . CS en bloques con etiqueta arriba
    private var ledTimeDisplay: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ledBlock(value: timeField(deck.elapsed, .min), label: "MIN")
            ledSep(":")
            ledBlock(value: timeField(deck.elapsed, .sec), label: "SEG")
            ledSep(".")
            ledBlock(value: timeField(deck.elapsed, .cs),  label: "CS")
        }
    }

    private func ledBlock(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .tracking(0.6)
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.ledDim)
                .frame(width: 54, height: 36, alignment: .center)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func ledSep(_ char: String) -> some View {
        Text(char)
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundColor(deck.loaded ? Theme.ledGreen.opacity(0.40) : Theme.ledDim)
            .padding(.bottom, 4)
    }

    private var largeBottomBar: some View {
        HStack(spacing: 10) {
            beatGrid(large: true)

            if !deck.key.isEmpty {
                Text(deck.key)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.purple)
            }

            Text(remainingText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)

            Spacer()

            if let progress = deck.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.08))
                        Rectangle()
                            .fill(deck.accent)
                            .frame(width: max(3, geo.size.width * progress))
                    }
                }
                .frame(width: 180, height: 4)

                Text(String(format: "%.0f%%", progress * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 28, alignment: .trailing)
            }

            ltcButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // ═══════════════════════════════════════
    // MARK: Vista Pequeña (cuadrícula 2 col)
    // ═══════════════════════════════════════

    private var smallBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 3) {
                    Text(deck.kindLabel)
                        .font(.system(size: 6, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(Theme.textTertiary)
                    Text(deck.deckTag)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 26, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(deck.isPlaying ? deck.accent : Theme.rowDivider, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(titleText)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary)
                        .lineLimit(1)
                    if !deck.artist.isEmpty {
                        Text(deck.artist)
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(bpmText)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(deck.bpm > 0 ? Theme.ledGreen : Theme.ledDim)
                    Text("BPM")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)

            WaveformView(
                progress:    deck.progress,
                trackLength: deck.trackLength,
                bpm:         deck.bpm,
                beatInBar:   deck.beatInBar,
                isPlaying:   deck.isPlaying,
                accent:      deck.accent,
                trackSeed:   deck.trackSeed,
                peaks: deck.peaks,
                cuePositionFraction: deck.cuePositionFraction,
                loopInFraction:  deck.loopInFraction,
                loopOutFraction: deck.loopOutFraction,
                mode: .scrolling,
                windowSeconds: isHot ? 8 : 24
            )
            .id(deck.id)
            .frame(height: isHot ? 54 : 36)
            .opacity(deck.loaded && (deck.progress != nil || !deck.peaks.isEmpty) ? 1 : 0.28)
            .transaction { $0.animation = nil }

            HStack(spacing: 8) {
                Text(formatMS(deck.elapsed))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.ledDim)
                beatGrid(large: false)
                Spacer()
                if deck.isMaster { LEDTag(text: "MST", color: Theme.accent) }
                if isLTCSource { LEDTag(text: "LTC", color: Theme.purple) }
                ltcButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Theme.deckFill)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(deck.isPlaying ? deck.accent : Color.clear)
                .frame(width: 2)
        }
        .overlay(
            Rectangle().stroke(Theme.rowDivider, lineWidth: 1)
        )
    }

    // ═══════════════════════════════════════
    // MARK: Componentes compartidos
    // ═══════════════════════════════════════

    private var ltcButton: some View {
        Button(action: onSelectLTC) {
            HStack(spacing: 3) {
                if isLTCSource {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 7))
                }
                Text("SMPTE")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.3)
            }
            .foregroundColor(isLTCSource ? .black : Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Rectangle()
                    .fill(isLTCSource ? Theme.ledGreen : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(isLTCSource
              ? "Este deck está emitiendo LTC. Pulsa para detener este generador (no reactiva el Master auto)."
              : "Activar SMPTE LTC de esta pista en la salida asignada a esta fila.")
    }

    private var titleText: String {
        if !deck.loaded { return "SIN PISTA" }
        if deck.title.isEmpty { return "SIN TITULO" }
        return deck.title
    }

    private var bpmText: String {
        deck.bpm > 0 ? String(format: "%.2f", deck.bpm) : "---.--"
    }

    private func beatGrid(large: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(1...4, id: \.self) { pos in
                Rectangle()
                    .fill(beatColor(pos))
                    .frame(width: pos == 1 ? 10 : 7, height: large ? 16 : 10)
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
        let t: Double
        if let s, s.isFinite, s >= 0 {
            t = s
        } else if deck.loaded {
            t = 0
        } else {
            return "--"
        }
        switch f {
        case .min: return String(format: "%02d", Int(t) / 60)
        case .sec: return String(format: "%02d", Int(t) % 60)
        case .cs:  return String(format: "%02d", Int(t * 100) % 100)
        }
    }

    private func formatMS(_ seconds: Double?) -> String {
        if let s = seconds, s.isFinite, s >= 0 {
            let cs = Int(s * 100) % 100
            let totalSec = Int(s)
            return String(format: "%02d:%02d.%02d", totalSec / 60, totalSec % 60, cs)
        }
        if deck.loaded { return "00:00.00" }
        return "--:--.--"
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
            .padding(.vertical, 1)
            .background(Rectangle().fill(color.opacity(0.16)))
    }
}
