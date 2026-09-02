// ContentView.swift
// Ventana principal: cabecera con selector de modo + toggle Grande/Pequeño,
// pila de decks (2, 4 o más en modo dual), log opcional y créditos.

import SwiftUI
import AppKit
import StageLinqKit

enum AppMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case denon = "Denon"
    case pioneer = "Pioneer"
    case dual = "Dual"

    var id: String { rawValue }
}

enum DeckLayout { case large, small }

struct ContentView: View {
    @EnvironmentObject var manager: StageLinqManager
    @EnvironmentObject var proDJLink: ProDJLinkManager

    @EnvironmentObject var outputs: OutputController
    @EnvironmentObject var testLink: TestLinkReceiver
    @EnvironmentObject var license: LicenseStore

    @State private var mode: AppMode = .auto
    @State private var layout: DeckLayout = .small
    @State private var showLog = false
    @State private var showOutputs = false

    /// En modo Auto elegimos según lo que haya realmente con pista, no por
    /// dispositivos vacíos (simulador Denon ON sin audio, CDJ virtual, etc.).
    private var effectiveMode: AppMode {
        guard mode == .auto else { return mode }
        let hasDenon = denonLoadedCount > 0
        let hasPioneer = pioneerRowCount > 0
        if hasDenon && hasPioneer { return .dual }
        if hasPioneer { return .pioneer }
        if hasDenon { return .denon }
        return .dual
    }

    private var denonLoadedCount: Int {
        if testLink.roster.denonOn {
            return testLink.roster.denonLoadedCount
        }
        return manager.devices.reduce(0) { acc, device in
            acc + device.decks.filter { $0.songLoaded && !TrackNaming.cleanTitle($0.trackTitle).isEmpty }.count
        }
    }

    private var pioneerRowCount: Int {
        var n = 0
        if shouldShowTestPioneer { n += 1 }
        n += proDJLink.devices.filter { isRealLoadedPioneer($0) }.count
        return n
    }

    /// Pioneer TEST no necesita un CDJ descubierto por UDP: el título, BPM,
    /// waveform y playhead van por TestLink. Si Denon TEST ya muestra esa
    /// pista, Auto/Dual no la clonan; el modo Pioneer sí la enseña.
    private var shouldShowTestPioneer: Bool {
        guard testLink.roster.hasPioneerTrack else { return false }
        if mode == .pioneer { return true }
        if mode == .denon { return false }
        return !testLink.roster.denonOn
    }

    private func isRealLoadedPioneer(_ device: ProDJLinkDevice) -> Bool {
        if device.isOwnVirtualCDJ { return false }
        if device.looksLikeLegacyFakeClock { return false }
        if device.isLocalTestSimulator { return false }
        return device.trackLoaded
    }

    /// Con Denon TEST preferimos el SC6000-SIM para no mezclar un SC6000 real.
    private var denonDevicesForTest: [StageLinqDevice] {
        let sims = manager.devices.filter { $0.name.uppercased().contains("SIM") }
        return sims.isEmpty ? manager.devices : sims
    }

    /// Cada entrada guarda el objeto observable original, no una copia: así la
    /// fila se refresca sola cuando cambia el estado del deck.
    private var entries: [DeckEntry] {
        let _ = manager.rosterRevision
        let _ = proDJLink.rosterRevision
        let _ = testLink.rosterTick
        var rows: [DeckEntry] = []
        let showDenon = effectiveMode == .denon || effectiveMode == .dual
        let showPioneer = effectiveMode == .pioneer || effectiveMode == .dual

        if showDenon {
            if testLink.roster.denonOn {
                // TEST: una fila por capa A/B con archivo. Si StageLinq aún no
                // ha visto el sim, la fila nace igual desde TestLink.
                var usedLayers = Set<Int>()
                let devices = denonDevicesForTest
                for device in devices {
                    for deck in device.decks {
                        let idx = deck.id - 1
                        guard testLink.roster.layerLoaded(idx) else { continue }
                        guard usedLayers.insert(idx).inserted else { continue }
                        rows.append(.denon(deck: deck, device: device))
                    }
                }
                for idx in 0..<2 {
                    guard testLink.roster.layerLoaded(idx) else { continue }
                    guard usedLayers.insert(idx).inserted else { continue }
                    rows.append(.denonTest(layer: idx))
                }
            } else {
                for device in manager.devices {
                    for deck in device.decks {
                        let title = TrackNaming.cleanTitle(deck.trackTitle)
                        guard deck.songLoaded && !title.isEmpty else { continue }
                        rows.append(.denon(deck: deck, device: device))
                    }
                }
            }
        }
        if showPioneer {
            if shouldShowTestPioneer {
                rows.append(.pioneerTest)
            }
            for device in proDJLink.devices {
                if !isRealLoadedPioneer(device) { continue }
                rows.append(.pioneer(device: device))
            }
        }
        return rows
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            header

            if entries.isEmpty {
                EmptyStateView(mode: effectiveMode)
            } else if layout == .large {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            deckRow(entry, isLarge: true)
                        }
                    }
                    .transaction { $0.animation = nil }
                }
            } else {
                compactMasterStack
            }

            if showLog {
                Rectangle().fill(Theme.rowDivider).frame(height: 1)
                LogView().frame(height: 150)
            }

            CreditsFooter()
            }

            if !license.isUnlocked {
                ActivationView()
            }
        }
        .background(Theme.background)
        .background(BlackWindowConfigurator())
        .sheet(isPresented: $showOutputs) {
            OutputsView()
                .environmentObject(outputs)
                .environmentObject(license)
        }
    }

    private var compactFocusID: String? {
        outputs.ltcSourceDeckID ?? outputs.hotDeckID ?? outputs.ltcFollowedDeckID
    }

    private var compactMasterEntry: DeckEntry? {
        if let focus = compactFocusID {
            if let found = entries.first(where: { OutputController.sameDeckID($0.id, focus) }) {
                return found
            }
        }
        return entries.first
    }

    private func isCompactFocus(_ entry: DeckEntry) -> Bool {
        guard let master = compactMasterEntry else { return false }
        return OutputController.sameDeckID(master.id, entry.id)
    }

    /// MASTER grande + los dos repros pequeños. Sin `let` dentro del ViewBuilder.
    private var compactMasterStack: some View {
        ScrollView {
            VStack(spacing: 0) {
                compactHeroRow
                if entries.count > 1 {
                    Rectangle().fill(Theme.rowDivider).frame(height: 2)
                    ForEach(entries) { entry in
                        deckRow(entry, isLarge: false, isHero: false)
                            .overlay(alignment: .leading) {
                                compactFocusBar(entry)
                            }
                    }
                }
            }
            .transaction { $0.animation = nil }
        }
    }

    @ViewBuilder
    private var compactHeroRow: some View {
        if let master = compactMasterEntry {
            deckRow(master, isLarge: true, isHero: true)
        }
    }

    @ViewBuilder
    private func compactFocusBar(_ entry: DeckEntry) -> some View {
        if isCompactFocus(entry) {
            Rectangle().fill(Theme.accent).frame(width: 3)
        }
    }

    @ViewBuilder
    private func deckRow(_ entry: DeckEntry, isLarge: Bool, isHero: Bool = false) -> some View {
        switch entry {
        case .denon(let deck, let device):
            DenonDeckRow(deck: deck, device: device, isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .small })
        case .pioneer(let device):
            PioneerDeckRow(device: device, isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .small })
        case .pioneerTest:
            PioneerTestRow(isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .small })
        case .denonTest(let layer):
            DenonTestRow(layer: layer, isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .small })
        }
    }

    private func masterSwitcher(_ entries: [DeckEntry], current: DeckEntry?) -> some View {
        HStack(spacing: 6) {
            Text("MST")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundColor(Theme.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(entries) { entry in
                        switcherChip(entry, current: current)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.strip)
    }

    private func switcherChip(_ entry: DeckEntry, current: DeckEntry?) -> some View {
        let on = current.map { OutputController.sameDeckID($0.id, entry.id) } ?? false
        return Button {
            outputs.pinMaster(to: entry.id)
        } label: {
            Text(switcherLabel(entry))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(on ? .black : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Rectangle().fill(on ? Theme.accent : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func switcherLabel(_ entry: DeckEntry) -> String {
        switch entry {
        case .denon(let deck, _):
            let t = TrackNaming.cleanTitle(deck.trackTitle)
            return t.isEmpty ? "DECK \(deck.id)" : t
        case .pioneer(let device):
            let t = TrackNaming.cleanTitle(device.trackTitle)
            return t.isEmpty ? "P\(device.playerNumber)" : t
        case .pioneerTest:
            return "PIONEER TEST"
        case .denonTest(let layer):
            return layer == 0 ? "DENON A" : "DENON B"
        }
    }

    private var outputsActive: Bool {
        outputs.resolumeEnabled || outputs.ltcAnyEnabled
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("STAGE CONNECT")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.6)
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 10) {
                    SourceCount(label: "DENON", count: denonLoadedCount, color: Theme.accent)
                    SourceCount(label: "PIONEER", count: pioneerRowCount, color: Theme.cyan)
                }
            }

            Spacer()

            HStack(spacing: 1) {
                layoutButton(icon: "rectangle.stack", mode: .large, help: "Todos los reproductores en grande")
                layoutButton(icon: "rectangle.grid.2x2", mode: .small, help: "MASTER grande + los dos reproductores pequeños")
            }

            Picker("", selection: $mode) {
                ForEach(AppMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 248)
            .labelsHidden()

            Button {
                if outputs.ltcEnabled {
                    outputs.stopMasterLTC()
                } else {
                    outputs.enableMasterAutoFollow()
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(outputs.ltcEnabled ? Theme.ledGreen : Theme.textTertiary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text("MASTER")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundColor(outputs.ltcEnabled ? Theme.ledGreen : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("LTC de casa: sigue al deck master / On Air / el que está sonando. Apagar corta el generador.")

            Button {
                showOutputs = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                    Text("CONFIG")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundColor(outputsActive ? Theme.ledGreen : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Ajustes: timecode, Resolume, monitor web e historial")

            Button {
                showLog.toggle()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundColor(showLog ? Theme.accent : Theme.textSecondary)
                    .frame(width: 26, height: 24)
                    .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Ver el log de protocolo")
        }
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Theme.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowDivider).frame(height: 1)
        }
    }

    private func layoutButton(icon: String, mode targetLayout: DeckLayout, help: String) -> some View {
        let active = layout == targetLayout
        return Button { layout = targetLayout } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(active ? .black : Theme.textSecondary)
                .frame(width: 28, height: 24)
                .background(Rectangle().fill(active ? Theme.cyan : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
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
        HStack {
            Text("entikrecords.com")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.0)
                .foregroundColor(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.black)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.rowDivider).frame(height: 1)
        }
    }
}

/// Quita el chrome gris de macOS: barra de título transparente y fondo negro.
private struct BlackWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(nsView.window)
    }

    private func apply(_ window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
    }
}

// MARK: - Entradas y filas observadoras

enum DeckEntry: Identifiable {
    case denon(deck: DeckState, device: StageLinqDevice)
    case pioneer(device: ProDJLinkDevice)
    case pioneerTest
    case denonTest(layer: Int)

    var id: String {
        switch self {
        case .denon(let deck, let device): return "denon-\(device.id)-\(deck.id)"
        case .pioneer(let device): return "pioneer-\(device.id)"
        case .pioneerTest: return DeckDisplayBuilder.testPioneerID
        case .denonTest(let layer): return DeckDisplayBuilder.testDenonID(layer)
        }
    }
}

/// Observa el deck concreto para que la fila se actualice en tiempo real.
struct DenonDeckRow: View {
    @ObservedObject var deck: DeckState
    let device: StageLinqDevice
    var isLarge: Bool = true
    var isHero: Bool = false
    var onFocusMaster: () -> Void = {}
    @EnvironmentObject var outputs: OutputController
    @EnvironmentObject var testLink: TestLinkReceiver

    var body: some View {
        let overlay = testLink.roster.denonOn ? testLink.snapshot?.deck(deck.id - 1) : nil
        let display = denonDisplay(overlay: overlay)
        let ltcID = overlay != nil
            ? DeckDisplayBuilder.testDenonID(deck.id - 1)
            : display.id
        PlayerDeckRow(
            deck: display,
            isLarge: isLarge,
            isHero: isHero,
            isLTCSource: outputs.isRowLTCLit(ltcID),
            isMasterFocus: outputs.isMasterFocus(ltcID),
            isHot: outputs.isWaveformHot(ltcID),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(ltcID) },
            onPinMaster: {
                outputs.pinMaster(to: ltcID)
                onFocusMaster()
            }
        )
    }

    private func denonDisplay(overlay: TestLinkDeck?) -> DeckDisplay {
        var display = DeckDisplayBuilder.row(
            for: deck, device: device, overlay: overlay
        )
        let ltcID = overlay != nil
            ? DeckDisplayBuilder.testDenonID(deck.id - 1)
            : display.id
        display.ltcTimecode = outputs.ltcDeckTimecode[ltcID]
            ?? (outputs.isRowLTCLit(ltcID) && outputs.ltcEnabled
                ? outputs.ltcTimecode
                : nil)
        display.signalAt = overlay != nil ? testLink.lastPacketAt : deck.lastPacketAt
        return display
    }
}

struct PioneerDeckRow: View {
    @ObservedObject var device: ProDJLinkDevice
    var isLarge: Bool = true
    var isHero: Bool = false
    var onFocusMaster: () -> Void = {}
    @EnvironmentObject var outputs: OutputController

    var body: some View {
        let display = pioneerDisplay
        PlayerDeckRow(
            deck: display,
            isLarge: isLarge,
            isHero: isHero,
            isLTCSource: outputs.isRowLTCLit(display.id),
            isMasterFocus: outputs.isMasterFocus(display.id),
            isHot: outputs.isWaveformHot(display.id),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(display.id) },
            onPinMaster: {
                outputs.pinMaster(to: display.id)
                onFocusMaster()
            }
        )
    }

    private var pioneerDisplay: DeckDisplay {
        var display = DeckDisplayBuilder.row(for: device, overlay: nil)
        display.ltcTimecode = outputs.ltcDeckTimecode[display.id]
            ?? (outputs.isRowLTCLit(display.id) && outputs.ltcEnabled
                ? outputs.ltcTimecode
                : nil)
        display.signalAt = device.lastSeen
        return display
    }
}

/// Fila Pioneer TEST: solo TestLink. No espera un CDJ en UDP :50000
/// (rekordbox, puerto ocupado o broadcast local que no vuelve).
struct PioneerTestRow: View {
    var isLarge: Bool = true
    var isHero: Bool = false
    var onFocusMaster: () -> Void = {}
    @EnvironmentObject var outputs: OutputController
    @EnvironmentObject var testLink: TestLinkReceiver

    var body: some View {
        let display = pioneerTestDisplay
        PlayerDeckRow(
            deck: display,
            isLarge: isLarge,
            isHero: isHero,
            isLTCSource: outputs.isRowLTCLit(display.id),
            isMasterFocus: outputs.isMasterFocus(display.id),
            isHot: outputs.isWaveformHot(display.id),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(display.id) },
            onPinMaster: {
                outputs.pinMaster(to: display.id)
                onFocusMaster()
            }
        )
    }

    private var pioneerTestDisplay: DeckDisplay {
        let overlay = testLink.snapshot?.decks.first(where: { $0.loaded && $0.playing })
            ?? testLink.snapshot?.firstLoadedDeck()
        var display = DeckDisplayBuilder.testPioneer(overlay: overlay)
        display.ltcTimecode = outputs.ltcDeckTimecode[display.id]
            ?? (outputs.isRowLTCLit(display.id) && outputs.ltcEnabled
                ? outputs.ltcTimecode
                : nil)
        display.signalAt = overlay != nil ? testLink.lastPacketAt : .distantPast
        return display
    }
}

/// Fila Denon TEST cuando StageLinq aún no ha descubierto el simulador.
struct DenonTestRow: View {
    let layer: Int
    var isLarge: Bool = true
    var isHero: Bool = false
    var onFocusMaster: () -> Void = {}
    @EnvironmentObject var outputs: OutputController
    @EnvironmentObject var testLink: TestLinkReceiver

    var body: some View {
        let display = denonTestDisplay
        PlayerDeckRow(
            deck: display,
            isLarge: isLarge,
            isHero: isHero,
            isLTCSource: outputs.isRowLTCLit(display.id),
            isMasterFocus: outputs.isMasterFocus(display.id),
            isHot: outputs.isWaveformHot(display.id),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(display.id) },
            onPinMaster: {
                outputs.pinMaster(to: display.id)
                onFocusMaster()
            }
        )
    }

    private var denonTestDisplay: DeckDisplay {
        let overlay = testLink.snapshot?.deck(layer)
        var display = DeckDisplayBuilder.testDenon(layer: layer, overlay: overlay)
        display.ltcTimecode = outputs.ltcDeckTimecode[display.id]
            ?? (outputs.isRowLTCLit(display.id) && outputs.ltcEnabled
                ? outputs.ltcTimecode
                : nil)
        display.signalAt = overlay != nil ? testLink.lastPacketAt : .distantPast
        return display
    }
}

// MARK: - Construcción de filas desde cada protocolo

enum DeckDisplayBuilder {
    static let testPioneerID = "pioneer-test"
    static func testDenonID(_ layer: Int) -> String { "denon-test-\(layer)" }

    static func testPioneer(overlay: TestLinkDeck?) -> DeckDisplay {
        let title = TrackNaming.cleanTitle(overlay?.title ?? "")
        let loaded = overlay?.loaded == true
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0)
        let playing = overlay?.playing == true
        var display = DeckDisplay(
            id: testPioneerID,
            source: .pioneer,
            label: "CDJ-3000 · TEST",
            title: title,
            artist: overlay?.artist ?? "",
            key: MusicalKey.resolved(raw: overlay?.key ?? "", title: title, artist: overlay?.artist ?? ""),
            genre: overlay?.genre ?? "",
            album: overlay?.album ?? "",
            comment: overlay?.comment ?? "",
            bpm: bpm,
            pitchPercent: nil,
            isPlaying: playing,
            isMaster: overlay?.isMaster == true || playing,
            isOnAir: false,
            isSynced: false,
            loaded: loaded,
            stateLabel: playing ? "Play" : (loaded ? "Pausa" : "Stop"),
            beatInBar: MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm),
            beatPulse: false,
            elapsed: overlay?.position,
            trackLength: overlay?.duration,
            progress: overlay?.progress,
            accent: Theme.cyan,
            cuePositionFraction: nil,
            loopInFraction: nil,
            loopOutFraction: nil,
            peaks: overlay?.peaks ?? [],
            peaksLow: overlay?.peaksLow ?? [],
            peaksMid: overlay?.peaksMid ?? [],
            peaksHigh: overlay?.peaksHigh ?? []
        )
        display.signalAt = overlay != nil ? Date() : .distantPast
        display.controlStamp = controlStamp(
            playing: playing,
            master: overlay?.isMaster == true || playing,
            loaded: loaded,
            state: playing ? "Play" : (loaded ? "Pausa" : "Stop"),
            title: title,
            key: overlay?.key ?? "",
            jog: playing ? 0 : Int((overlay?.position ?? 0) * 8)
        )
        return display
    }

    static func testDenon(layer: Int, overlay: TestLinkDeck?) -> DeckDisplay {
        let title = TrackNaming.cleanTitle(overlay?.title ?? "")
        let loaded = overlay?.loaded == true
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0)
        let playing = overlay?.playing == true
        let name = layer == 0 ? "A" : "B"
        var display = DeckDisplay(
            id: testDenonID(layer),
            source: .denon,
            label: "SC6000 · TEST \(name)",
            title: title,
            artist: overlay?.artist ?? "",
            key: MusicalKey.resolved(raw: overlay?.key ?? "", title: title, artist: overlay?.artist ?? ""),
            genre: overlay?.genre ?? "",
            album: overlay?.album ?? "",
            comment: overlay?.comment ?? "",
            bpm: bpm,
            pitchPercent: nil,
            isPlaying: playing,
            isMaster: overlay?.isMaster == true,
            isOnAir: false,
            isSynced: false,
            loaded: loaded,
            stateLabel: playing ? "Play" : (loaded ? "Pausa" : "Stop"),
            beatInBar: MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm),
            beatPulse: false,
            elapsed: overlay?.position,
            trackLength: overlay?.duration,
            progress: overlay?.progress,
            accent: Theme.deckAccent(layer),
            cuePositionFraction: nil,
            loopInFraction: nil,
            loopOutFraction: nil,
            peaks: overlay?.peaks ?? [],
            peaksLow: overlay?.peaksLow ?? [],
            peaksMid: overlay?.peaksMid ?? [],
            peaksHigh: overlay?.peaksHigh ?? []
        )
        display.signalAt = overlay != nil ? Date() : .distantPast
        display.controlStamp = controlStamp(
            playing: playing,
            master: overlay?.isMaster == true,
            loaded: loaded,
            state: playing ? "Play" : (loaded ? "Pausa" : "Stop"),
            title: title,
            key: overlay?.key ?? "",
            jog: playing ? 0 : Int((overlay?.position ?? 0) * 8)
        )
        return display
    }

    static func row(for deck: DeckState, device: StageLinqDevice, overlay: TestLinkDeck? = nil) -> DeckDisplay {
        let layer = deck.id == 1 ? "A" : (deck.id == 2 ? "B" : "\(deck.id)")
        let deviceName = device.name.isEmpty ? device.ip : device.name
        let title = TrackNaming.cleanTitle(overlay?.title ?? deck.trackTitle)
        let artist = overlay?.artist ?? deck.trackArtist
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0, deck.bpm, deck.beatBpm)
        let progress = overlay?.progress ?? deck.beatProgress
        let length = overlay?.duration ?? (deck.trackLength > 0 ? deck.trackLength : nil)
        let elapsed: Double? = {
            if let o = overlay { return o.position }
            if let p = progress, let l = length { return p * l }
            return nil
        }()
        let playing = overlay?.playing ?? (deck.playState == .playing)
        let loaded = overlay?.loaded ?? (deck.songLoaded && !title.isEmpty)
        let overlayKey = overlay?.key ?? ""
        let key = MusicalKey.resolved(
            raw: overlayKey.isEmpty ? deck.trackKey : overlayKey,
            title: title,
            artist: artist
        )
        let state = playing ? "Play" : stateLabel(deck.playState)

        var display = DeckDisplay(
            id: "denon-\(device.id)-\(deck.id)",
            source: .denon,
            label: "SC6000 · \(deviceName) \(layer)",
            title: title,
            artist: artist,
            key: key,
            genre: overlay?.genre.isEmpty == false ? overlay!.genre : deck.genre,
            album: overlay?.album ?? "",
            comment: overlay?.comment ?? "",
            bpm: bpm,
            pitchPercent: nil,
            isPlaying: playing,
            isMaster: overlay?.isMaster ?? deck.isMaster,
            isOnAir: overlay != nil ? false : (deck.volume > 0.05),
            isSynced: false,
            loaded: loaded,
            stateLabel: state,
            beatInBar: overlay != nil
                ? MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm)
                : beatInBar(deck.currentBeat),
            beatPulse: overlay != nil ? false : deck.beatPulse,
            elapsed: elapsed,
            trackLength: length,
            progress: progress,
            accent: Theme.deckAccent(deck.id - 1),
            cuePositionFraction: frac(deck.cuePosition, length: length),
            loopInFraction: frac(deck.loopInPosition, length: length),
            loopOutFraction: frac(deck.loopOutPosition, length: length),
            peaks: overlay?.peaks ?? [],
            peaksLow: overlay?.peaksLow ?? [],
            peaksMid: overlay?.peaksMid ?? [],
            peaksHigh: overlay?.peaksHigh ?? []
        )
        display.signalAt = overlay != nil ? Date() : deck.lastPacketAt
        _ = deck.activityTick
        display.controlStamp = controlStamp(
            playing: playing,
            master: overlay?.isMaster ?? deck.isMaster,
            loaded: loaded,
            state: state,
            title: title,
            key: key,
            volume: Int((deck.volume * 100).rounded()),
            speed: Int((deck.speed * 200).rounded()),
            cue: Int((max(deck.cuePosition, 0) * 10).rounded()),
            loop: deck.loopEnabled,
            scratch: deck.scratchTouch,
            jog: playing ? 0 : Int((elapsed ?? 0) * 8)
        )
        return display
    }

    static func row(for device: ProDJLinkDevice, overlay: TestLinkDeck? = nil) -> DeckDisplay {
        let label = "\(device.model.isEmpty ? "CDJ" : device.model) · PLAYER \(device.playerNumber)"
        let overlayTitle = overlay?.title ?? ""
        let title = TrackNaming.cleanTitle(overlayTitle.isEmpty ? device.trackTitle : overlayTitle)
        let loaded = overlay?.loaded ?? device.trackLoaded
        let hasPlayhead = overlay?.progress != nil
            || (device.trackLoaded && device.hasPosition && device.trackLength > 0)
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0, device.effectiveBPM, device.trackBPM)
        let progress = overlay?.progress ?? (hasPlayhead ? device.progress : nil)
        let length = overlay?.duration ?? (hasPlayhead ? device.trackLength : nil)
        let elapsed = overlay?.position ?? (hasPlayhead ? device.playhead : nil)
        let pitch: Double? = {
            if overlay != nil { return nil }
            return device.trackLoaded && abs(device.pitchPercent) > 0.01 ? device.pitchPercent : nil
        }()
        let overlayKey = overlay?.key ?? ""
        let artist = (overlay?.artist).flatMap { $0.isEmpty ? nil : $0 } ?? (device.trackArtist.isEmpty ? "" : device.trackArtist)
        let key = MusicalKey.resolved(
            raw: overlayKey.isEmpty ? device.trackKey : overlayKey,
            title: title,
            artist: artist
        )
        let playing = overlay?.playing ?? (device.trackLoaded && device.isPlaying)
        let state = playing ? "Play" : device.playModeLabel

        var display = DeckDisplay(
            id: "pioneer-\(device.id)",
            source: .pioneer,
            label: label,
            title: title,
            artist: artist,
            key: key,
            genre: overlay?.genre.isEmpty == false ? overlay!.genre : device.trackGenre,
            album: overlay?.album.isEmpty == false ? overlay!.album : device.trackAlbum,
            comment: overlay?.comment.isEmpty == false ? overlay!.comment : device.trackComment,
            bpm: loaded ? bpm : 0,
            pitchPercent: pitch,
            isPlaying: playing,
            isMaster: overlay?.isMaster ?? (device.trackLoaded && device.isMaster),
            isOnAir: overlay != nil ? false : (device.trackLoaded && device.isOnAir),
            isSynced: overlay != nil ? false : (device.trackLoaded && device.isSynced),
            loaded: loaded,
            stateLabel: state,
            beatInBar: overlay != nil
                ? MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm)
                : device.beatInBar,
            beatPulse: false,
            elapsed: elapsed,
            trackLength: length,
            progress: progress,
            accent: Theme.deckAccent((device.playerNumber - 1 + 4) % 4),
            cuePositionFraction: nil,
            loopInFraction: nil,
            loopOutFraction: nil,
            peaks: overlay?.peaks ?? device.peaks,
            peaksLow: overlay?.peaksLow ?? device.peaksLow,
            peaksMid: overlay?.peaksMid ?? device.peaksMid,
            peaksHigh: overlay?.peaksHigh ?? device.peaksHigh
        )
        display.signalAt = overlay != nil ? Date() : device.lastSeen
        _ = device.activityTick
        display.controlStamp = controlStamp(
            playing: playing,
            master: overlay?.isMaster ?? (device.trackLoaded && device.isMaster),
            onAir: overlay != nil ? false : (device.trackLoaded && device.isOnAir),
            synced: overlay != nil ? false : (device.trackLoaded && device.isSynced),
            loaded: loaded,
            state: state,
            title: title,
            key: key,
            pitch: Int(((pitch ?? 0) * 10).rounded()),
            jog: playing ? 0 : Int((elapsed ?? 0) * 8)
        )
        return display
    }

    private static func controlStamp(
        playing: Bool,
        master: Bool,
        onAir: Bool = false,
        synced: Bool = false,
        loaded: Bool,
        state: String,
        title: String,
        key: String,
        volume: Int = 0,
        speed: Int = 0,
        pitch: Int = 0,
        cue: Int = 0,
        loop: Bool = false,
        scratch: Bool = false,
        jog: Int = 0
    ) -> Int {
        var h = 5381
        func mix(_ v: Int) { h = ((h &<< 5) &+ h) &+ v }
        mix(playing ? 1 : 0)
        mix(master ? 1 : 0)
        mix(onAir ? 1 : 0)
        mix(synced ? 1 : 0)
        mix(loaded ? 1 : 0)
        mix(loop ? 1 : 0)
        mix(scratch ? 1 : 0)
        mix(volume)
        mix(speed)
        mix(pitch)
        mix(cue)
        mix(jog)
        mix(hashStr(state))
        mix(hashStr(title))
        mix(hashStr(key))
        return h
    }

    private static func hashStr(_ s: String) -> Int {
        var h = 0
        for u in s.unicodeScalars { h = h &* 31 &+ Int(u.value) }
        return h
    }

    private static func frac(_ seconds: Double, length: Double?) -> Double? {
        guard seconds >= 0, let l = length, l > 0 else { return nil }
        return min(1, max(0, seconds / l))
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
