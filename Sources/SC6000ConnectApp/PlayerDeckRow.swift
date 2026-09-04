// PlayerDeckRow.swift
// Fila de deck: Grande (monitor tipo ShowKontrol) y Pequeña (mosaico 2 col).

import SwiftUI
import AppKit
import StageLinqKit

// MARK: - Modelo normalizado

struct DeckDisplay: Identifiable {
    enum Source { case denon, pioneer, serato, virtualdj }

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
    var extraCueFractions: [Double] = []
    /// Loop activo en el reproductor (Engine / overlay / Pioneer Loop).
    var loopEnabled: Bool = false
    var loopSizeBeats: Double = 0
    /// Índices 1…8 de QuickLoop activos (Denon).
    var activeQuickLoops: [Int] = []
    var peaks: [UInt8] = []             // waveform real (TEST); vacío = procedural
    var peaksLow: [UInt8] = []
    var peaksMid: [UInt8] = []
    var peaksHigh: [UInt8] = []
    var ltcTimecode: String? = nil       // TC timecode para mostrar (SMPTE / deck LTC)
    var artworkImage: NSImage? = nil
    /// Clave UserDefaults de la etiqueta (token+layer, IP+player, TEST, software).
    var labelKey: String = ""
    /// Último paquete del reproductor (jog, play, fader, StateMap…).
    var signalAt: Date = .distantPast
    /// Huella de controles discretos (play, cue, loop, fader, pitch…). Cambia → flash LED.
    var controlStamp: Int = 0
    /// BPM del disco sin pitch. 0 = no hay dato separado.
    var trackBPM: Double = 0
    /// Pioneer: pitch del fader (0x98). nil = no llegó.
    var faderPitchPercent: Double? = nil
    var playerSlot: String = ""

    var playbackRate: Double? {
        guard let pitchPercent, pitchPercent.isFinite else { return nil }
        return 1.0 + pitchPercent / 100.0
    }

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

    var kindLabel: String {
        switch source {
        case .denon: return "DECK"
        case .pioneer: return "PLAYER"
        case .serato: return "SERATO"
        case .virtualdj: return "VDJ"
        }
    }

    var sourceBrand: String {
        switch source {
        case .denon: return "Denon"
        case .pioneer: return "Pioneer"
        case .serato: return "Serato"
        case .virtualdj: return "VDJ"
        }
    }

    /// Identificador corto para la tira izquierda (A/B, DECK 3/4 o player).
    var deckTag: String {
        let parts = label.split(separator: " ").map(String.init)
        if let num = parts.reversed().first(where: { Int($0) != nil }) {
            return num
        }
        let last = parts.last ?? ""
        if last.count <= 2 { return last.uppercased() }
        switch source {
        case .pioneer, .serato, .virtualdj: return "1"
        case .denon: return "A"
        }
    }
}

// MARK: - Fila principal

struct PlayerDeckRow: View {
    let deck: DeckDisplay
    var isLarge: Bool = true
    var isHero: Bool = false
    /// Vista Master: la onda ocupa el hueco vertical (no un alto fijo).
    var fillsAvailable: Bool = false
    var isLTCSource: Bool = false
    var isMasterFocus: Bool = false
    var isLocked: Bool = false
    var isHot: Bool = false
    var ltcAutoFollow: Bool = true
    var onSelectLTC: () -> Void = {}
    var onPinMaster: () -> Void = {}
    var onToggleLock: () -> Void = {}

    @EnvironmentObject private var artwork: ArtworkFetcher
    @EnvironmentObject private var labels: DeckLabelStore
    @EnvironmentObject private var outputs: OutputController
    @EnvironmentObject private var localization: LocalizationStore
    @Environment(\.waveformWindowSeconds) private var waveformWindowSeconds
    @State private var editingTag = false
    @State private var tagDraft = ""

    var body: some View {
        Group {
            if isLarge { largeBody } else { smallBody }
        }
        .transaction { $0.animation = nil }
        .onAppear { requestArtwork() }
        .onChange(of: deck.title) { _ in requestArtwork() }
        .onChange(of: deck.artist) { _ in requestArtwork() }
        .onChange(of: deck.loaded) { _ in requestArtwork() }
    }

    // ═══════════════════════════════════════
    // MARK: Vista Grande (monitor DJ)
    // ═══════════════════════════════════════

    private var largeBody: some View {
        HStack(alignment: .top, spacing: 0) {
            deckIndexStrip

            VStack(spacing: 0) {
                largeMetaRow
                deckWaveform(mode: .scrolling, windowSeconds: waveformWindowSeconds)
                    .id(deck.id)
                    .frame(minHeight: fillsAvailable ? 180 : (isHero ? 148 : 96))
                    .frame(maxHeight: fillsAvailable ? .infinity : (isHero ? 148 : 96))
                    .opacity(waveformOpacity)
                    .transaction { $0.animation = nil }
                if isHero, hasExtendedMeta { largeDetailRow }
                largeBottomBar
            }
            .frame(maxHeight: fillsAvailable ? .infinity : nil)
        }
        .frame(maxHeight: fillsAvailable ? .infinity : nil)
        .background(Theme.deckFill)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(deck.isPlaying ? deck.accent : Color.clear)
                .frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowDivider).frame(height: 1)
        }
        .contextMenu { tagContextMenu }
    }

    private var deckIndexStrip: some View {
        VStack(spacing: 5) {
            Text(deck.kindLabel)
                .font(.system(size: 7, weight: .bold))
                .tracking(1.1)
                .foregroundColor(Theme.textTertiary)

            tagButton(size: 20, width: 34, height: 26)

            playStateBadge(compact: false)

            DeckSignalLED(signalAt: deck.signalAt, stamp: deck.controlStamp)

            if isLocked { LEDTag(text: "LOCK", color: Theme.yellow) }
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
            if showsArtwork { artworkThumb(size: isHero ? 52 : 40) }

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(deck.loaded ? Theme.ledGreen : Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                cueLoopBadges

                HStack(spacing: 8) {
                    if !artistText.isEmpty {
                        Text(artistText)
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
                    Text(deck.label.uppercased())
                        .font(.system(size: 8, weight: .medium))
                        .tracking(0.4)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { requestArtwork() }
            .onChange(of: deck.title) { _ in requestArtwork() }
            .onChange(of: deck.artist) { _ in requestArtwork() }

            ledTimeDisplay

            keyBadge(size: isHero ? 22 : 18)

            VStack(alignment: .trailing, spacing: 1) {
                if let pitch = deck.pitchPercent, abs(pitch) > 0.01 {
                    Text(String(format: "%+.2f%%", pitch))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyan)
                }
                if let rate = deck.playbackRate, abs((rate - 1) * 100) > 0.01 {
                    Text(String(format: "%.3f×", rate))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
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
                if deck.trackBPM > 0, let pitch = deck.pitchPercent, abs(pitch) > 0.01,
                   abs(deck.trackBPM - deck.bpm) > 0.04 {
                    Text(String(format: "disco %.2f", deck.trackBPM))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var hasExtendedMeta: Bool {
        !deck.album.isEmpty || !deck.genre.isEmpty || !deck.key.isEmpty || !deck.comment.isEmpty
            || deck.faderPitchPercent != nil || !deck.playerSlot.isEmpty
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
            if !deck.playerSlot.isEmpty {
                metaChip(label: "SLOT", value: deck.playerSlot)
            }
            if let fader = deck.faderPitchPercent, abs(fader) > 0.01 {
                metaChip(label: "FADER", value: String(format: "%+.2f%%", fader))
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

    private var resolvedLabelKey: String {
        deck.labelKey.isEmpty ? deck.id : deck.labelKey
    }

    private var displayedTag: String {
        let raw = labels.tag(for: resolvedLabelKey) ?? deck.deckTag
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if u == "TEST" || u == "SIM" || u == "SC6000-SIM" || u == "SC6000 TEST" {
            return deck.deckTag
        }
        return raw
    }

    private func tagButton(size: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Button {
            tagDraft = displayedTag
            editingTag = true
        } label: {
            Text(displayedTag)
                .font(.system(size: displayedTag.count > 3 ? size * 0.62 : size, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(width: width, height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(deck.isPlaying ? deck.accent : Theme.rowDivider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Clic para cambiar letra, número o nombre de este deck")
        .popover(isPresented: $editingTag, arrowEdge: .trailing) {
            tagEditor
        }
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ETIQUETA DEL DECK")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.textTertiary)
            TextField("A, 1, MAIN…", text: $tagDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .padding(8)
                .background(Color.black)
                .overlay(Rectangle().stroke(Theme.rowDivider, lineWidth: 1))
                .onSubmit { commitTag() }
            HStack(spacing: 4) {
                ForEach(["A", "B", "C", "D", "1", "2", "3", "4", "5", "6", "7", "8"], id: \.self) { chip in
                    Button(chip) {
                        tagDraft = chip
                        commitTag()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Theme.overlay(0.08))
                }
            }
            HStack {
                Button("MAIN") { tagDraft = "MAIN"; commitTag() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.accent)
                Spacer()
                Button("Restablecer") {
                    labels.clear(resolvedLabelKey)
                    editingTag = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                Button("Guardar") { commitTag() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.ledGreen)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.panel)
    }

    private func commitTag() {
        labels.setTag(tagDraft, for: resolvedLabelKey)
        editingTag = false
    }

    @ViewBuilder
    private var tagContextMenu: some View {
        Button("Renombrar deck…") {
            tagDraft = displayedTag
            editingTag = true
        }
        Button("Restablecer etiqueta") { labels.clear(resolvedLabelKey) }
    }

    private func requestArtwork() {
        if let img = deck.artworkImage {
            artwork.seed(artist: deck.artist, title: deck.title, image: img)
            return
        }
        artwork.fetch(artist: deck.artist, title: deck.title)
    }

    private var resolvedArtwork: NSImage? {
        ArtworkPixels.displayable(deck.artworkImage)
            ?? ArtworkPixels.displayable(artwork.artwork(artist: deck.artist, title: deck.title))
    }

    /// Solo si hay CGImage. Sin píxeles no se reserva hueco (Denon real / iTunes vacío).
    private var showsArtwork: Bool { resolvedArtwork != nil }

    @ViewBuilder
    private func artworkThumb(size: CGFloat) -> some View {
        if let img = resolvedArtwork, let cg = ArtworkPixels.cgImage(img) {
            Image(decorative: cg, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
                .overlay(Rectangle().stroke(Theme.rowDivider, lineWidth: 1))
        }
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
        outputs.displayTimecode(deckID: deck.id, elapsed: deck.elapsed)
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
                        .stroke(Theme.overlay(0.08), lineWidth: 1)
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

            Spacer(minLength: 8)

            if let progress = deck.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.overlay(0.08))
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

            HStack(spacing: 6) {
                lockButton
                masterButton
                ltcButton
            }
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
                    Text(deck.kindLabel)
                        .font(.system(size: 6, weight: .bold))
                        .tracking(0.4)
                        .foregroundColor(Theme.textTertiary)
                    tagButton(size: 13, width: 28, height: 20)
                    playStateBadge(compact: true)
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
                    cueLoopBadges
                    if !artistText.isEmpty {
                        Text(artistText)
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

                // BPM + pitch
                VStack(alignment: .trailing, spacing: 0) {
                    Text(bpmText)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(deck.bpm > 0 ? Theme.ledGreen : Theme.ledDim)
                    if let pitch = deck.pitchPercent, abs(pitch) > 0.01 {
                        Text(String(format: "%+.2f%%", pitch))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.cyan)
                    } else {
                        Text("BPM")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .padding(.trailing, 8)

                // Tags + action buttons
                HStack(spacing: 4) {
                    Text(displayedTimecode)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(keyText)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(deck.key.isEmpty ? Theme.textTertiary : Theme.purple)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if isLTCSource { LEDTag(text: "LTC", color: Theme.purple) }
                    HStack(spacing: 4) {
                        lockButton
                        masterButton
                        ltcButton
                    }
                    .layoutPriority(2)
                }
                .padding(.trailing, 6)
            }
            .padding(.vertical, 5)
            .background(Theme.deckFill)

            // ── Overview: pista entera ────────────────────────────────────
            deckWaveform(mode: .overview, windowSeconds: waveformWindowSeconds)
                .id(deck.id + "-ov")
                .frame(height: 68)
                .opacity(waveformOpacity)
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
        .contextMenu { tagContextMenu }
    }

    // ═══════════════════════════════════════
    // MARK: Componentes compartidos
    // ═══════════════════════════════════════

    private var waveformProgress: Double? {
        if let p = deck.progress, p.isFinite { return min(max(p, 0), 1) }
        if let e = deck.elapsed, let l = deck.trackLength, l > 0, e.isFinite {
            return min(max(e / l, 0), 1)
        }
        return nil
    }

    private var waveformOpacity: Double {
        let hasPeaks = !deck.peaks.isEmpty || deck.peaksLow.count > 1
        let hasLength = (deck.trackLength ?? 0) > 0
        if deck.loaded && (waveformProgress != nil || hasPeaks || hasLength) { return 1 }
        return isLarge ? 0.28 : 0.22
    }

    private func deckWaveform(mode: WaveformMode, windowSeconds: Double) -> WaveformView {
        WaveformView(
            progress:            waveformProgress,
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
            elapsed:             deck.elapsed,
            cuePositionFraction: deck.cuePositionFraction,
            extraCueFractions:   deck.extraCueFractions,
            loopInFraction:      deck.loopInFraction,
            loopOutFraction:     deck.loopOutFraction,
            mode:                mode,
            windowSeconds:       windowSeconds,
            playbackRate:        deck.playbackRate ?? 1.0
        )
    }

    private func playStateBadge(compact: Bool) -> some View {
        let playing = deck.isPlaying
        let paused = deck.loaded && !playing
        let label = playing ? localization.t("deck.play")
            : (paused ? localization.t("deck.pause") : localization.t("deck.stop"))
        let color = playing ? Theme.ledGreen : (paused ? Theme.yellow : Theme.textTertiary)
        return VStack(spacing: compact ? 1 : 2) {
            Circle()
                .fill(color)
                .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
                .shadow(color: playing ? color.opacity(0.95) : .clear, radius: compact ? 2 : 3.5)
            Text(label)
                .font(.system(size: compact ? 6 : 7, weight: .bold))
                .tracking(0.3)
                .foregroundColor(color)
        }
        .help(label)
        .id(localization.language)
    }

    private var lockButton: some View {
        Button(action: onToggleLock) {
            HStack(spacing: 3) {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 7))
                Text(localization.t("deck.lock"))
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.3)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(isLocked ? .black : Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Rectangle()
                    .fill(isLocked ? Theme.yellow : Theme.buttonBg)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(isLocked
              ? "Salida de este deck anclada. El MASTER de casa no la pisa ni cambia su generador."
              : "Anclar el LTC de esta fila. El MASTER sigue a otro deck en la salida de casa.")
    }

    private var ltcButton: some View {
        Button(action: onSelectLTC) {
            HStack(spacing: 3) {
                if isLTCSource {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 7))
                }
                Text(localization.t("deck.smpte"))
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.3)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(isLTCSource ? .black : Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Rectangle()
                    .fill(isLTCSource ? Theme.ledGreen : Theme.buttonBg)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(isLTCSource
              ? "Este deck está emitiendo LTC. Pulsa para detener este generador (no reactiva el Master auto)."
              : "Activar SMPTE LTC de esta pista en la salida asignada a esta fila.")
    }

    private var masterButton: some View {
        Button(action: { onPinMaster() }) {
            HStack(spacing: 3) {
                Image(systemName: isMasterFocus ? "crown.fill" : "crown")
                    .font(.system(size: 7))
                Text(localization.t("deck.master"))
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.3)
                    .lineLimit(1)
                    .fixedSize()
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
        .fixedSize()
        .help(isMasterFocus
              ? "Esta es la pista MASTER en monitor. Pulsa de nuevo para seguir al que está sonando."
              : "Mostrar esta pista en grande (vista MASTER). No activa SMPTE.")
    }

    private var titleText: String {
        if !deck.loaded { return localization.t("deck.notLoaded") }
        let title = TrackNaming.cleanTitle(deck.title)
        if title.isEmpty { return localization.t("deck.noTitle") }
        return title
    }

    @ViewBuilder
    private var cueLoopBadges: some View {
        let hasCue = deck.cuePositionFraction != nil || !deck.extraCueFractions.isEmpty
        let hasLoop = deck.loopEnabled
            || (deck.loopInFraction != nil && deck.loopOutFraction != nil)
        let qs = deck.activeQuickLoops
        if hasCue || hasLoop || !qs.isEmpty {
            HStack(spacing: 4) {
                if hasCue {
                    Text("CUE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                }
                if hasLoop {
                    Text(deck.loopSizeBeats > 0
                          ? String(format: "LOOP %.0fB", deck.loopSizeBeats)
                          : "LOOP")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.ledGreen)
                }
                ForEach(qs, id: \.self) { n in
                    Text("QL\(n)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Theme.cyan)
                }
            }
        }
    }

    private var artistText: String {
        TrackNaming.cleanTitle(deck.artist)
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
        guard deck.beatInBar == pos else { return Color.primary.opacity(0.10) }
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
            let lit = flash ? Color.white : (live ? Theme.ledGreen : Theme.overlay(0.12))
            VStack(spacing: compact ? 0 : 2) {
                ZStack {
                    Capsule()
                        .fill(Color.black)
                        .frame(width: compact ? 9 : 11, height: compact ? 14 : 20)
                        .overlay(Capsule().stroke(Theme.overlay(0.14), lineWidth: 1))
                    Capsule()
                        .fill(lit)
                        .frame(width: compact ? 4 : 5, height: compact ? 8 : 12)
                        .shadow(
                            color: flash ? Theme.overlay(0.95)
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
