// DeckCardView.swift
// Tarjeta visual de un deck lógico: pista, BPM, key, estado, loop, beat en
// vivo (pulso animado sincronizado con BeatInfo) y volumen.

import SwiftUI
import StageLinqKit

struct DeckCardView: View {
    @ObservedObject var deck: DeckState
    let title: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.panelBorder)

            if deck.songLoaded {
                loadedContent
            } else {
                emptyContent
            }
        }
        .panelStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(deck.playState == .playing ? accent.opacity(0.55) : Theme.panelBorder, lineWidth: deck.playState == .playing ? 1.5 : 1)
        )
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundColor(Theme.textSecondary)
            Spacer()
            if deck.isMaster {
                Label("MASTER", systemImage: "crown.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.accent)
            }
            BeatPulseView(pulse: deck.beatPulse, active: deck.playState == .playing, accent: accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Contenido con pista cargada

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.trackTitle.isEmpty ? "Sin título" : deck.trackTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(deck.trackArtist.isEmpty ? "—" : deck.trackArtist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 16) {
                MetricView(icon: "waveform.path.ecg", value: deck.bpm > 0 ? String(format: "%.2f", deck.bpm) : "—", label: "BPM", color: Theme.cyan)
                MetricView(icon: "music.note", value: deck.trackKey.isEmpty ? "—" : deck.trackKey, label: "KEY", color: Theme.purple)
                if !deck.genre.isEmpty {
                    MetricView(icon: "tag", value: deck.genre, label: "GENRE", color: Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                PlayStateBadge(state: deck.playState, accent: accent)
                if deck.loopEnabled {
                    Badge(text: "LOOP", icon: "repeat", color: Theme.yellow)
                }
                if deck.keyLock {
                    Badge(text: "KEY LOCK", icon: "lock.fill", color: Theme.textTertiary)
                }
                Spacer()
            }

            progressSection

            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                VolumeMeter(level: deck.volume, accent: accent)
            }
        }
        .padding(14)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accent)
                        .frame(width: geo.size.width * progressFraction)
                }
            }
            .frame(height: 5)

            HStack {
                Text(formatTime(elapsedSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                if deck.beatProgress != nil {
                    Text("beat \(Int(deck.currentBeat))/\(Int(deck.totalBeats))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                Text(formatTime(deck.trackLength))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    /// Prioriza la posición derivada de BeatInfo (más precisa y de mayor
    /// frecuencia); si no hay datos de beat, no mostramos progreso inventado.
    private var progressFraction: Double {
        deck.beatProgress ?? 0
    }

    private var elapsedSeconds: Double {
        guard let bp = deck.beatProgress else { return 0 }
        return bp * deck.trackLength
    }

    // MARK: - Sin pista

    private var emptyContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 26))
                .foregroundColor(Theme.textTertiary)
            Text("Sin pista cargada")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct MetricView: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9)).foregroundColor(color)
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
            }
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .tracking(0.5)
                .foregroundColor(Theme.textTertiary)
        }
    }
}

private struct Badge: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }
}

private struct PlayStateBadge: View {
    let state: PlayState
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }

    var icon: String {
        switch state {
        case .playing: return "play.fill"
        case .paused: return "pause.fill"
        case .stopped: return "stop.fill"
        }
    }
    var text: String {
        switch state {
        case .playing: return "PLAY"
        case .paused: return "PAUSA"
        case .stopped: return "STOP"
        }
    }
    var color: Color {
        switch state {
        case .playing: return Theme.green
        case .paused: return Theme.yellow
        case .stopped: return Theme.textTertiary
        }
    }
}

private struct VolumeMeter: View {
    let level: Double // 0...1
    let accent: Color
    private let segments = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color(for: i))
                    .frame(width: 4, height: 8)
            }
        }
    }

    private func color(for index: Int) -> Color {
        let threshold = Double(index) / Double(segments)
        guard level > threshold else { return Color.white.opacity(0.08) }
        if index > segments * 8 / 10 { return Theme.red }
        if index > segments * 6 / 10 { return Theme.yellow }
        return Theme.green
    }
}

/// Punto que "late" al ritmo del beat recibido por BeatInfo.
private struct BeatPulseView: View {
    let pulse: Bool
    let active: Bool
    let accent: Color
    @State private var flash = false

    var body: some View {
        Circle()
            .fill(active ? accent : Theme.textTertiary.opacity(0.3))
            .frame(width: 9, height: 9)
            .scaleEffect(flash ? 1.6 : 1.0)
            .opacity(flash ? 1.0 : 0.7)
            .animation(.easeOut(duration: 0.18), value: flash)
            .onChange(of: pulse) { _ in
                guard active else { return }
                flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { flash = false }
            }
    }
}
