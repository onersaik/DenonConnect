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
    let genre: String
    let album: String
    let comment: String
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
    var peaks: [UInt8] = []             // waveform real (TEST); vacío = procedural
    var peaksLow: [UInt8] = []
    var peaksMid: [UInt8] = []
    var peaksHigh: [UInt8] = []
    var ltcTimecode: String? = nil       // TC timecode para mostrar (SMPTE / deck LTC)
    var artworkImage: NSImage? = nil
    /// Último paquete del reproductor (jog, play, fader, StateMap…).
    var signalAt: Date = .distantPast
    /// Huella de controles discretos (play, cue, loop, fader, pitch…). Cambia → flash LED.
    var controlStamp: Int = 0

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
    var isHero: Bool = false
    var isLTCSource: Bool = false
    var isMasterFocus: Bool = false
    var isHot: Bool = false
    var ltcAutoFollow: Bool = true
    var onSelectLTC: () -> Void = {}
    var onPinMaster: () -> Void = {}

    @EnvironmentObject private var artwork: ArtworkFetcher

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
                    peaksLow: deck.peaksLow,
                    peaksMid: deck.peaksMid,
                    peaksHigh: deck.peaksHigh,
                    cuePositionFraction: deck.cuePositionFraction,
                    loopInFraction:  deck.loopInFraction,
                    loopOutFraction: deck.loopOutFraction,
                    mode: .scrolling,
                    windowSeconds: isHero ? 10 : 12
                )
                .id(deck.id)
                .frame(height: isHero ? 148 : 96)
                .opacity(deck.loaded && (deck.progress != nil || !deck.peaks.isEmpty) ? 1 : 0.28)
                .transaction { $0.animation = nil }
                if isHero, hasExtendedMeta { largeDetailRow }
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

            DeckSignalLED(signalAt: deck.signalAt, stamp: deck.controlStamp)

            if isMasterFocus || deck.isMaster { LEDTag(text: "MST", color: Theme.accent) }
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
            artworkThumb(size: isHero ? 52 : 40)

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
                    if !deck.genre.isEmpty {
                        Text(deck.genre)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.cyan)
                            .lineLimit(1)
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
            .onAppear { artwork.fetch(artist: deck.artist, title: deck.title) }

            ledTimeDisplay

            keyBadge(size: isHero ? 22 : 18)

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

    private var hasExtendedMeta: Bool {
        !deck.album.isEmpty || !deck.genre.isEmpty || !deck.key.isEmpty || !deck.comment.isEmpty
    }

    private var largeDetailRow: some View {
        HStack(alignment: .top, spacing: 16) {
            if !deck.album.isEmpty {
                metaChip(label: "ÁLBUM", value: deck.album)
            }
            if !deck.genre.isEmpty {
                metaChip(label: "GÉNERO", value: deck.genre)
            }
            if !deck.key.isEmpty {
                metaChip(label: "NOTA", value: deck.key)
            }
            if !deck.comment.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("COMENTARIOS")
                        .font(.system(size: 7, weight: .bold))
                        .tracking(0.6)
                        .foregroundColor(Theme.textTertiary)
                    Text(deck.comment)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.strip)
    }

    private func metaChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .tracking(0.6)
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
    }

    private func artworkThumb(size: CGFloat) -> some View {
        let img = artwork.artwork(artist: deck.artist, title: deck.title) ?? deck.artworkImage
        return Group {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.32))
                            .foregroundColor(Theme.textTertiary)
                    )
            }
        }
        .overlay(Rectangle().stroke(Theme.rowDivider, lineWidth: 1))
    }
    private var ledTimeDisplay: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(alignment: .bottom, spacing: 3) {
                ledBlock(value: timeField(deck.elapsed, .min), label: "MIN")
                ledSep(":")
                ledBlock(value: timeField(deck.elapsed, .sec), label: "SEG")
                ledSep(".")
                ledBlock(value: timeField(deck.elapsed, .cs),  label: "CS")
            }
            HStack(spacing: 6) {
                Text("TC")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(Theme.textTertiary)
                Text(displayedTimecode)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(deck.loaded ? Theme.accent : Theme.ledDim)
            }
        }
    }

    private var displayedTimecode: String {
        if let tc = deck.ltcTimecode, !tc.isEmpty, !(tc == "00:00:00:00" && (deck.elapsed ?? 0) > 0.04) {
            return tc
        }
        return LTCGenerator.timecodeText(seconds: deck.elapsed ?? 0, fps: 25)
    }

    private var keyText: String {
        deck.key.isEmpty ? "—" : deck.key
    }

    private func keyBadge(size: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text("KEY")
                .font(.system(size: 7, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.textTertiary)
            Text(keyText)
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundColor(deck.key.isEmpty ? Theme.ledDim : Theme.purple)
                .frame(minWidth: 44)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(deck.key.isEmpty ? Theme.rowDivider : Theme.purple.opacity(0.45), lineWidth: 1)
                )
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

            if let tc = deck.ltcTimecode {
                Text(tc)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Rectangle().fill(Theme.accent.opacity(0.12)))
            }

            if !deck.key.isEmpty {
                Text(deck.key)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.purple)
            }
            if !deck.album.isEmpty {
                Text(deck.album)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
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

            masterButton
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
            // ── Header row ──────────────────────────────────────────────
            HStack(spacing: 0) {
                // Deck tag strip
                VStack(spacing: 2) {
                    Text(deck.deckTag)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                    Image(systemName: deck.isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 7))
                        .foregroundColor(deck.isPlaying ? Theme.ledGreen : Theme.textTertiary)
                    DeckSignalLED(signalAt: deck.signalAt, stamp: deck.controlStamp, compact: true)
                }
                .frame(width: 32)
                .frame(maxHeight: .infinity)
                .background(Theme.strip)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.rowDivider).frame(width: 1)
                }

                // Title + artist
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary)
                        .lineLimit(1)
                    if !deck.artist.isEmpty {
                        Text(deck.artist)
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Elapsed time
                Text(formatMS(deck.elapsed))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.ledDim)
                    .padding(.trailing, 8)

                // BPM
                VStack(alignment: .trailing, spacing: 0) {
                    Text(bpmText)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(deck.bpm > 0 ? Theme.ledGreen : Theme.ledDim)
                    Text("BPM")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                }
                .padding(.trailing, 8)

                // Tags + action buttons
                HStack(spacing: 4) {
                    Text(displayedTimecode)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.accent)
                    Text(keyText)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(deck.key.isEmpty ? Theme.textTertiary : Theme.purple)
                    if isLTCSource { LEDTag(text: "LTC", color: Theme.purple) }
                    masterButton
                    ltcButton
                }
                .padding(.trailing, 6)
            }
            .padding(.vertical, 5)
            .background(Theme.deckFill)

            // ── Overview waveform ────────────────────────────────────────
            WaveformView(
                progress:            deck.progress,
                trackLength:         deck.trackLength,
                bpm:                 deck.bpm,
                beatInBar:           deck.beatInBar,
                isPlaying:           deck.isPlaying,
                accent:              deck.accent,
                trackSeed:           deck.trackSeed,
                peaks:               deck.peaks,
                peaksLow:            deck.peaksLow,
                peaksMid:            deck.peaksMid,
                peaksHigh:           deck.peaksHigh,
                cuePositionFraction: deck.cuePositionFraction,
                loopInFraction:      deck.loopInFraction,
                loopOutFraction:     deck.loopOutFraction,
                mode:                .overview
            )
            .id(deck.id + "-ov")
            .frame(height: 52)
            .opacity(deck.loaded && (deck.progress != nil || !deck.peaks.isEmpty) ? 1 : 0.22)
            .transaction { $0.animation = nil }
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

    private var masterButton: some View {
        Button(action: { onPinMaster() }) {
            HStack(spacing: 3) {
                Image(systemName: isMasterFocus ? "crown.fill" : "crown")
                    .font(.system(size: 7))
                Text("MST")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.3)
            }
            .foregroundColor(isMasterFocus ? .black : Theme.accent.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Rectangle()
                    .fill(isMasterFocus ? Theme.accent : Theme.accent.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help(isMasterFocus
              ? "Esta es la pista MASTER en monitor. Pulsa de nuevo para seguir al que está sonando."
              : "Mostrar esta pista en grande (vista MASTER). No activa SMPTE.")
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

/// LED de recepción tipo reproductor: vivo con cualquier paquete, flash al pulsar/jog/fader.
struct DeckSignalLED: View {
    let signalAt: Date
    let stamp: Int
    var compact: Bool = false

    @State private var flashUntil: Date = .distantPast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let now = timeline.date
            let live = now.timeIntervalSince(signalAt) < 0.9
            let flash = now < flashUntil
            let lit = flash ? Color.white : (live ? Theme.ledGreen : Color.white.opacity(0.12))
            VStack(spacing: compact ? 0 : 2) {
                ZStack {
                    Capsule()
                        .fill(Color.black)
                        .frame(width: compact ? 9 : 11, height: compact ? 14 : 20)
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    Capsule()
                        .fill(lit)
                        .frame(width: compact ? 4 : 5, height: compact ? 8 : 12)
                        .shadow(
                            color: flash ? Color.white.opacity(0.95)
                                : (live ? Theme.ledGreen.opacity(0.9) : .clear),
                            radius: flash ? 5 : (live ? 3.5 : 0)
                        )
                }
                if !compact {
                    Text("RX")
                        .font(.system(size: 6, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(flash || live ? Theme.ledGreen : Theme.textTertiary)
                }
            }
        }
        .onChange(of: stamp) { _ in
            flashUntil = Date().addingTimeInterval(0.32)
        }
        .help("Señal del reproductor: jog, play, cue, loop, fader o cualquier paquete.")
    }
}
