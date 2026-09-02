// ContentView.swift
// Ventana principal estilo reproductor: cabecera con selector de modo,
// pila de decks (2, 4 o más en modo dual), log opcional y créditos.

import SwiftUI
import StageLinqKit

enum AppMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case denon = "Denon"
    case pioneer = "Pioneer"
    case dual = "Dual"

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var manager: StageLinqManager
    @EnvironmentObject var proDJLink: ProDJLinkManager

    @State private var mode: AppMode = .auto
    @State private var showLog = false

    /// En modo Auto elegimos según lo que haya realmente en la red.
    private var effectiveMode: AppMode {
        guard mode == .auto else { return mode }
        let hasDenon = !manager.devices.isEmpty
        let hasPioneer = !proDJLink.devices.isEmpty
        if hasDenon && hasPioneer { return .dual }
        if hasPioneer { return .pioneer }
        if hasDenon { return .denon }
        return .dual
    }

    /// Cada entrada guarda el objeto observable original, no una copia: así la
    /// fila se refresca sola cuando cambia el estado del deck.
    private var entries: [DeckEntry] {
        var rows: [DeckEntry] = []
        let showDenon = effectiveMode == .denon || effectiveMode == .dual
        let showPioneer = effectiveMode == .pioneer || effectiveMode == .dual

        if showDenon {
            for device in manager.devices {
                let loaded = device.decks.filter { $0.songLoaded }
                let shown = loaded.isEmpty ? Array(device.decks.prefix(2)) : loaded
                for deck in shown {
                    rows.append(.denon(deck: deck, device: device))
                }
            }
        }
        if showPioneer {
            for device in proDJLink.devices {
                rows.append(.pioneer(device: device))
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.panelBorder)

            if entries.isEmpty {
                EmptyStateView(mode: effectiveMode)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .denon(let deck, let device):
                                DenonDeckRow(deck: deck, device: device)
                            case .pioneer(let device):
                                PioneerDeckRow(device: device)
                            }
                        }
                    }
                    .padding(14)
                }
            }

            if showLog {
                Divider().background(Theme.panelBorder)
                LogView().frame(height: 150)
            }

            Divider().background(Theme.panelBorder)
            CreditsFooter()
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SC6000 CONNECT")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 8) {
                    SourceCount(label: "DENON", count: manager.devices.count, color: Theme.accent)
                    SourceCount(label: "PIONEER", count: proDJLink.devices.count, color: Theme.cyan)
                    if mode == .auto {
                        Text("auto → \(effectiveMode.rawValue.lowercased())")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }

            Spacer()

            Picker("", selection: $mode) {
                ForEach(AppMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .labelsHidden()

            Button {
                showLog.toggle()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundColor(showLog ? Theme.accent : Theme.textSecondary)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Ver el log de protocolo")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }
}

private struct SourceCount: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(count > 0 ? color : Theme.textTertiary.opacity(0.35))
                .frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.4)
                .foregroundColor(count > 0 ? Theme.textSecondary : Theme.textTertiary)
        }
    }
}

private struct EmptyStateView: View {
    let mode: AppMode

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 38))
                .foregroundColor(Theme.textTertiary)
            Text(searchText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Mismo switch o misma red WiFi que el Mac.\nAcepta el permiso de red local de macOS.\nCierra rekordbox si buscas CDJ.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchText: String {
        switch mode {
        case .denon: return "Buscando Denon SC6000…"
        case .pioneer: return "Buscando Pioneer CDJ…"
        default: return "Buscando reproductores en la red…"
        }
    }
}

private struct CreditsFooter: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("DJ SAIK")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundColor(Theme.accent)
            Text("@dj.saik")
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
            Text("@entikrecords")
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text("StageLinq · Pro DJ Link — no oficial")
                .font(.system(size: 9))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }
}

// MARK: - Entradas y filas observadoras

enum DeckEntry: Identifiable {
    case denon(deck: DeckState, device: StageLinqDevice)
    case pioneer(device: ProDJLinkDevice)

    var id: String {
        switch self {
        case .denon(let deck, let device): return "denon-\(device.id)-\(deck.id)"
        case .pioneer(let device): return "pioneer-\(device.id)"
        }
    }
}

/// Observa el deck concreto para que la fila se actualice en tiempo real.
struct DenonDeckRow: View {
    @ObservedObject var deck: DeckState
    let device: StageLinqDevice

    var body: some View {
        PlayerDeckRow(deck: DeckDisplayBuilder.row(for: deck, device: device))
    }
}

struct PioneerDeckRow: View {
    @ObservedObject var device: ProDJLinkDevice

    var body: some View {
        PlayerDeckRow(deck: DeckDisplayBuilder.row(for: device))
    }
}

// MARK: - Construcción de filas desde cada protocolo

enum DeckDisplayBuilder {
    static func row(for deck: DeckState, device: StageLinqDevice) -> DeckDisplay {
        let layer = deck.id == 1 ? "A" : (deck.id == 2 ? "B" : "\(deck.id)")
        let deviceName = device.name.isEmpty ? device.ip : device.name
        let progress = deck.beatProgress
        let elapsed: Double? = progress.map { $0 * deck.trackLength }

        return DeckDisplay(
            id: "denon-\(device.id)-\(deck.id)",
            source: .denon,
            label: "SC6000 · \(deviceName) \(layer)",
            title: deck.trackTitle,
            artist: deck.trackArtist,
            key: deck.trackKey,
            bpm: deck.bpm,
            pitchPercent: nil,
            isPlaying: deck.playState == .playing,
            isMaster: deck.isMaster,
            isOnAir: false,
            isSynced: false,
            loaded: deck.songLoaded,
            stateLabel: stateLabel(deck.playState),
            beatInBar: beatInBar(deck.currentBeat),
            beatPulse: deck.beatPulse,
            elapsed: elapsed,
            trackLength: deck.trackLength > 0 ? deck.trackLength : nil,
            progress: progress,
            accent: Theme.deckAccent(deck.id - 1)
        )
    }

    static func row(for device: ProDJLinkDevice) -> DeckDisplay {
        DeckDisplay(
            id: "pioneer-\(device.id)",
            source: .pioneer,
            label: "\(device.model.isEmpty ? "CDJ" : device.model) · PLAYER \(device.playerNumber)",
            // Pro DJ Link no transmite título ni artista: solo el ID interno.
            title: device.trackLoaded ? "Pista #\(device.trackID)" : "",
            artist: device.trackLoaded ? device.slotLabel : "",
            key: "",
            bpm: device.effectiveBPM,
            pitchPercent: device.pitchPercent,
            isPlaying: device.isPlaying,
            isMaster: device.isMaster,
            isOnAir: device.isOnAir,
            isSynced: device.isSynced,
            loaded: device.trackLoaded,
            stateLabel: device.playModeLabel,
            beatInBar: device.beatInBar,
            beatPulse: device.beatPulse,
            elapsed: device.hasPosition ? device.playhead : nil,
            trackLength: device.hasPosition && device.trackLength > 0 ? device.trackLength : nil,
            progress: device.hasPosition ? device.progress : nil,
            accent: Theme.deckAccent((device.playerNumber - 1 + 4) % 4)
        )
    }

    private static func stateLabel(_ state: PlayState) -> String {
        switch state {
        case .playing: return "Play"
        case .paused: return "Pausa"
        case .stopped: return "Stop"
        }
    }

    /// StageLinq da el beat absoluto; el compás se deriva de él.
    private static func beatInBar(_ currentBeat: Double) -> Int {
        guard currentBeat > 0 else { return 0 }
        return Int(currentBeat.truncatingRemainder(dividingBy: 4)) + 1
    }
}
