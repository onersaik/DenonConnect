// PlayerDeckRow.swift
// Fila estilo reproductor: dígitos LED de tiempo, BPM grande, key, rejilla de
// beats en vivo y barra de posición. Es la vista común para decks Denon
// (StageLinq) y Pioneer (Pro DJ Link), para que el modo Dual pueda apilar
// 2, 4 o más decks con la misma pinta.

import SwiftUI
import StageLinqKit

/// Datos ya normalizados de un deck, vengan del protocolo que vengan.
struct DeckDisplay: Identifiable {
    enum Source { case denon, pioneer }

    let id: String
    let source: Source
    let label: String          // "SC6000 · DECK 1A", "CDJ · PLAYER 2"
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
    let beatInBar: Int
    let beatPulse: Bool
    let elapsed: Double?       // segundos; nil si el protocolo no lo da
    let trackLength: Double?
    let progress: Double?      // 0…1; nil si no hay dato fiable
    let accent: Color
}

struct PlayerDeckRow: View {
    let deck: DeckDisplay

    var body: some View {
        HStack(spacing: 14) {
            statusColumn
            trackColumn
            Spacer(minLength: 8)
            beatGrid
            timeColumn
            bpmColumn
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(deck.isPlaying ? deck.accent.opacity(0.5) : Color.white.opacity(0.07),
                        lineWidth: deck.isPlaying ? 1.5 : 1)
        )
    }

    // MARK: Columna de estado

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(deck.isPlaying ? deck.accent : Theme.textTertiary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(deck.label)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 4) {
                if deck.isMaster { LEDTag(text: "MASTER", color: Theme.accent) }
                if deck.isOnAir { LEDTag(text: "ON AIR", color: Theme.red) }
                if deck.isSynced { LEDTag(text: "SYNC", color: Theme.cyan) }
            }
        }
        .frame(width: 130, alignment: .leading)
    }

    // MARK: Pista

    private var trackColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(deck.loaded ? (deck.title.isEmpty ? "—" : deck.title) : "SIN PISTA")
                .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }

            if let progress = deck.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(deck.accent)
                            .frame(width: max(2, geo.size.width * progress))
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(minWidth: 200, alignment: .leading)
    }

    // MARK: Rejilla de beats (dato real de red, no una onda inventada)

    private var beatGrid: some View {
        HStack(spacing: 3) {
            ForEach(1...4, id: \.self) { position in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(forBeat: position))
                    .frame(width: position == 1 ? 8 : 5, height: 16)
            }
        }
        .opacity(deck.isPlaying ? 1 : 0.35)
    }

    private func color(forBeat position: Int) -> Color {
        guard deck.beatInBar == position else { return Color.white.opacity(0.10) }
        return position == 1 ? Theme.accent : deck.accent
    }

    // MARK: Tiempo en dígitos LED

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(format(deck.elapsed))
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary.opacity(0.5))
            Text(remainingText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(width: 96, alignment: .trailing)
    }

    private var remainingText: String {
        guard let elapsed = deck.elapsed, let length = deck.trackLength, length > 0 else { return "--:--" }
        return "-" + format(max(length - elapsed, 0))
    }

    private func format(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: BPM

    private var bpmColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(deck.bpm > 0 ? String(format: "%.2f", deck.bpm) : "---.--")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(deck.bpm > 0 ? Theme.ledGreen : Theme.textTertiary.opacity(0.5))
            if let pitch = deck.pitchPercent {
                Text(String(format: "%+.2f%%", pitch))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            } else {
                Text("BPM")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(width: 84, alignment: .trailing)
    }
}

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
