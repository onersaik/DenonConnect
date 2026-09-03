// ContentView.swift
// Ventana principal: cabecera con selector de fuente + vistas CDJ / Overview / Master,
// zoom de pista, pila de decks, log y créditos.

import SwiftUI
import AppKit
import StageLinqKit

enum AppMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case denon = "Denon"
    case pioneer = "Pioneer"
    case dual = "Todos"
    case serato = "Serato"
    case virtualdj = "VDJ"

    var id: String { rawValue }
}

enum DeckLayout { case large, small, master }

struct ContentView: View {
    @EnvironmentObject var manager: StageLinqManager
    @EnvironmentObject var proDJLink: ProDJLinkManager

    @EnvironmentObject var outputs: OutputController
    @EnvironmentObject var testLink: TestLinkReceiver
    @EnvironmentObject var license: LicenseStore
    @EnvironmentObject var mapping: MappingController
    @EnvironmentObject var software: SoftwareDJManager
    @EnvironmentObject var labels: DeckLabelStore
    @Environment(\.openWindow) private var openWindow

    private var mode: AppMode {
        get { mapping.mode }
        nonmutating set { mapping.mode = newValue }
    }
    private var layout: DeckLayout {
        get { mapping.layout }
        nonmutating set { mapping.layout = newValue }
    }
    private var showLog: Bool {
        get { mapping.showLog }
        nonmutating set { mapping.showLog = newValue }
    }
    private var showOutputs: Bool {
        get { mapping.showOutputs }
        nonmutating set { mapping.showOutputs = newValue }
    }

    /// En modo Auto elegimos según lo que haya realmente con pista, no por
    /// dispositivos vacíos (simulador Denon ON sin audio, CDJ virtual, etc.).
    private var effectiveMode: AppMode {
        guard mode == .auto else { return mode }
        let families = [
            denonLoadedCount > 0,
            pioneerRowCount > 0,
            software.seratoLiveCount > 0,
            software.vdjLiveCount > 0
        ].filter { $0 }.count
        if families > 1 { return .dual }
        if software.seratoLiveCount > 0 { return .serato }
        if software.vdjLiveCount > 0 { return .virtualdj }
        if pioneerRowCount > 0 { return .pioneer }
        if denonLoadedCount > 0 { return .denon }
        return .dual
    }

    private var denonLoadedCount: Int {
        var n = 0
        if testLink.roster.denonOn {
            n += testLink.roster.denonLoadedCount
        }
        n += manager.devices.filter { !$0.isDenonSimulator }.reduce(0) { acc, device in
            acc + device.decks.filter(\.songLoaded).count
        }
        return n
    }

    private var pioneerRowCount: Int {
        var n = 0
        if shouldShowTestPioneer { n += 1 }
        n += proDJLink.devices.filter(\.isLANPlayerWithTrack).count
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

    /// SC6000 de LAN con pista. El overlay TEST no cuenta; el título puede
    /// llegar tarde (StateMap) y no debe ocultar el hardware.
    private func isRealLoadedDenon(_ device: StageLinqDevice, deck: DeckState) -> Bool {
        !device.isDenonSimulator && deck.songLoaded
    }

    /// Cada entrada guarda el objeto observable original, no una copia: así la
    /// fila se refresca sola cuando cambia el estado del deck.
    private var entries: [DeckEntry] {
        let _ = manager.rosterRevision
        let _ = proDJLink.rosterRevision
        let _ = testLink.rosterTick
        let _ = software.rosterTick
        var rows: [DeckEntry] = []
        let showDenon = effectiveMode == .denon || effectiveMode == .dual
        let showPioneer = effectiveMode == .pioneer || effectiveMode == .dual
        let showSerato = effectiveMode == .serato || effectiveMode == .dual
        let showVDJ = effectiveMode == .virtualdj || effectiveMode == .dual

        if showDenon {
            if testLink.roster.denonOn {
                // TEST: overlay solo en el SIM (token/nombre exacto). Un SC6000
                // real de la LAN no se tapa ni recibe título de TEST.
                var usedLayers = Set<Int>()
                for device in manager.devices where device.isDenonSimulator {
                    for deck in device.decks {
                        let idx = deck.id - 1
                        guard testLink.roster.layerLoaded(idx) else { continue }
                        guard usedLayers.insert(idx).inserted else { continue }
                        rows.append(.denon(deck: deck, device: device))
                    }
                }
                let testLayerCount = max(testLink.roster.loadedLayers.count, 4)
                for idx in 0..<testLayerCount {
                    guard testLink.roster.layerLoaded(idx) else { continue }
                    guard usedLayers.insert(idx).inserted else { continue }
                    rows.append(.denonTest(layer: idx))
                }
            }
            for device in manager.devices {
                for deck in device.decks where isRealLoadedDenon(device, deck: deck) {
                    rows.append(.denon(deck: deck, device: device))
                }
            }
        }
        if showPioneer {
            if shouldShowTestPioneer {
                rows.append(.pioneerTest)
            }
            for device in proDJLink.devices where device.isLANPlayerWithTrack {
                rows.append(.pioneer(device: device))
            }
        }
        if showSerato {
            for deck in software.liveDecks where deck.kind == .serato {
                rows.append(.software(deck))
            }
        }
        if showVDJ {
            for deck in software.liveDecks where deck.kind == .virtualdj {
                rows.append(.software(deck))
            }
        }
        return rows
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            header

            discoveryBanner

            if entries.isEmpty {
                EmptyStateView(mode: effectiveMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == .master {
                masterOnlyStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == .large {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            deckRow(entry, isLarge: true)
                        }
                    }
                    .transaction { $0.animation = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                compactMasterStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .environment(\.waveformWindowSeconds, mapping.waveformWindowSeconds)
        .onAppear { mapping.setVisibleRows(entries.map(\.id)) }
        .onChange(of: entries.map(\.id)) { mapping.setVisibleRows($0) }
        .sheet(isPresented: $mapping.showOutputs) {
            OutputsView()
                .environmentObject(outputs)
                .environmentObject(license)
                .environmentObject(mapping)
                .environmentObject(labels)
                .environmentObject(software)
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

    /// Solo el reproductor que manda el MASTER (waveform CDJ + TC + título).
    private var masterOnlyStack: some View {
        VStack(spacing: 0) {
            if entries.count > 1 {
                masterSwitcher(entries, current: compactMasterEntry)
            }
            if let master = compactMasterEntry {
                deckRow(master, isLarge: true, isHero: true)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
    }

    /// MASTER grande + todas las filas pequeñas (hasta 8+ scrolleable). Sin tope 4.
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
            DenonDeckRow(deck: deck, device: device, isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .master })
        case .pioneer(let device):
            PioneerDeckRow(device: device, isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .master })
        case .pioneerTest:
            PioneerTestRow(isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .master })
        case .denonTest(let layer):
            DenonTestRow(layer: layer, isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .master })
        case .software(let deck):
            SoftwareDeckRow(deck: deck, isLarge: isLarge, isHero: isHero, onFocusMaster: { layout = .master })
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
            return "CDJ-3000"
        case .denonTest(let layer):
            return DeckDisplayBuilder.productDenonLabel(layer: layer + 1)
        case .software(let deck):
            return deck.shortName
        }
    }

    private var outputsActive: Bool {
        outputs.resolumeEnabled || outputs.ltcAnyEnabled
    }

    private var discoveryWarnings: [String] {
        [manager.listenWarning, proDJLink.listenWarning]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private var discoveryBanner: some View {
        if !discoveryWarnings.isEmpty {
            Text(discoveryWarnings.joined(separator: "  ·  "))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.yellow)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.yellow.opacity(0.12))
        }
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
                    if software.seratoLiveCount > 0 {
                        SourceCount(label: "SERATO", count: software.seratoLiveCount, color: Theme.ledGreen)
                    }
                    if software.vdjLiveCount > 0 {
                        SourceCount(label: "VDJ", count: software.vdjLiveCount, color: Theme.purple)
                    }
                }
            }

            Spacer()

            HStack(spacing: 1) {
                stageViewButton("CDJ", mode: .large, help: "Aguja al centro, zoom de pista. Show / booth. Atajo: G")
                stageViewButton("Overview", mode: .small, help: "Pista entera por fila. El MASTER de arriba sí hace zoom. Atajo: P")
                stageViewButton("Master", mode: .master, help: "Solo el reproductor que manda el MASTER.")
            }

            waveformZoomChip

            Picker("", selection: $mapping.mode) {
                ForEach(AppMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            .labelsHidden()

            Button {
                if outputs.ltcEnabled {
                    outputs.stopMasterLTC()
                } else {
                    outputs.enableMasterAutoFollow()
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(outputs.ltcEnabled ? Theme.ledGreen : Color.black.opacity(0.45))
                        .frame(width: 7, height: 7)
                        .shadow(color: outputs.ltcEnabled ? Theme.ledGreen.opacity(0.9) : .clear, radius: 3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("MASTER")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.7)
                        if outputs.ltcEnabled {
                            Text(outputs.ltcAutoFollow ? "AUTO" : "PIN")
                                .font(.system(size: 7, weight: .bold))
                                .tracking(0.4)
                                .opacity(0.75)
                        }
                    }
                }
                .foregroundColor(outputs.ltcEnabled ? .black : Theme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Rectangle().fill(outputs.ltcEnabled ? Theme.ledGreen : Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("MASTER de casa: un LTC que sigue al deck master, On Air o el que suena. LOCK en una fila con salida propia no se pisa. Atajo: M")

            headerMapToggle(
                title: "KEY",
                on: mapping.keyboardEnabled,
                help: mapping.keyboardEnabled
                    ? "Teclado ON: 1–4 G P M, +/− zoom pista, F1–F4 = SMPTE de las primeras 4 filas. Pulsa para apagar."
                    : "Teclado OFF: las teclas no disparan acciones. Pulsa para activar."
            ) { mapping.keyboardEnabled.toggle() }

            headerMapToggle(
                title: "MIDI",
                on: mapping.midiEnabled,
                help: mapping.midiEnabled
                    ? "MIDI ON: usa el puerto elegido en CONFIG. Pulsa para ignorar CC y notas."
                    : "MIDI OFF: se ignoran CC y notas. Pulsa para activar el puerto."
            ) { mapping.midiEnabled.toggle() }

            Button {
                openWindow(id: "sc-monitor")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(.system(size: 10))
                    Text("MONITOR")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Ventana MONITOR: Solo TC, Solo datos, pantalla completa (F).")

            Button {
                openWindow(id: "sc-tracklist")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 10))
                    Text("SETLIST")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Setlist de concierto: carga una lista y marca lo que suena.")

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
            .help("Ajustes: timecode, Resolume, monitor web, historial y mapeo MIDI/teclado. Atajo: C")

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
            .help("Ver el log de protocolo. Atajo: L")
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

    private func headerMapToggle(title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(on ? Theme.ledGreen : Theme.textTertiary.opacity(0.35))
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
            }
            .foregroundColor(on ? Theme.ledGreen : Theme.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Rectangle().fill(Color.white.opacity(on ? 0.10 : 0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func stageViewButton(_ title: String, mode targetLayout: DeckLayout, help: String) -> some View {
        let active = layout == targetLayout
        return Button { layout = targetLayout } label: {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundColor(active ? .black : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Rectangle().fill(active ? Theme.cyan : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var waveformZoomChip: some View {
        HStack(spacing: 4) {
            Text("ZOOM")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundColor(Theme.textTertiary)
            Button {
                mapping.waveformWindowSeconds = WaveformZoom.zoomOut(mapping.waveformWindowSeconds)
            } label: {
                Text("-")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 20, height: 22)
                    .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Más contexto (ventana más larga). Atajo: -")
            Text(WaveformZoom.label(mapping.waveformWindowSeconds))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 36)
            Button {
                mapping.waveformWindowSeconds = WaveformZoom.zoomIn(mapping.waveformWindowSeconds)
            } label: {
                Text("+")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 20, height: 22)
                    .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Más detalle (ventana más corta). Atajo: +")
            Slider(
                value: Binding(
                    get: { mapping.waveformWindowSeconds },
                    set: { mapping.waveformWindowSeconds = WaveformZoom.clamp($0) }
                ),
                in: WaveformZoom.minSeconds...WaveformZoom.maxSeconds
            )
            .frame(width: 72)
            .help("CDJ y MASTER: ventana visible. Overview de filas sigue siendo la pista entera.")
        }
        .opacity(layout == .small ? 0.72 : 1)
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
    @EnvironmentObject var manager: StageLinqManager
    @EnvironmentObject var proDJLink: ProDJLinkManager
    @EnvironmentObject var software: SoftwareDJManager

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 38))
                .foregroundColor(Theme.textTertiary)
            Text(searchText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            if !bindLines.isEmpty {
                ForEach(bindLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.yellow)
                        .multilineTextAlignment(.center)
                }
            }
            if !seenLines.isEmpty {
                Text("Vistos, sin pista cargada:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                ForEach(seenLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyan)
                }
            }
            Text("Mismo switch o misma red WiFi que el Mac.\nSi usas WiFi, desactiva el aislamiento de AP (client isolation).\nAcepta el permiso de red local de macOS.\nSi el puerto 50000 está ocupado: cierra rekordbox.\nSi 51337 está ocupado: cierra otra copia de STAGE CONNECT.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bindLines: [String] {
        [manager.listenWarning, proDJLink.listenWarning]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var seenLines: [String] {
        let denon = manager.devices.map { device -> String in
            let name = DeckDisplayBuilder.displayDeviceName(device.name)
            let tcp: String
            switch device.connectionState {
            case .discovered, .connecting:
                tcp = "conectado / esperando pista"
            case .connected:
                tcp = device.services["StateMap"] == nil
                    ? "conectado / esperando pista"
                    : "conectado, sin pista"
            case .failed: tcp = "TCP falló"
            }
            return "\(name) · \(tcp)"
        }
        let pioneer = proDJLink.devices
            .filter { !$0.isOwnVirtualCDJ && !$0.isMixer }
            .map { device -> String in
                let extra = device.hasStatus ? "conectado, sin pista" : "en red, esperando estado"
                return "\(DeckDisplayBuilder.productPioneerLabel(player: Int(device.playerNumber), model: device.model)) · \(extra)"
            }
        return denon + pioneer
    }

    private var searchText: String {
        // HOWDY recibido (aunque StateMap aún no): no es “buscando”.
        if !manager.devices.isEmpty, mode != .pioneer {
            return "conectado / esperando pista"
        }
        if !seenLines.isEmpty { return "Reproductores en la red — carga una pista" }
        switch mode {
        case .denon: return "Buscando Denon SC6000…"
        case .pioneer: return "Buscando Pioneer CDJ…"
        case .serato: return software.seratoStatus
        case .virtualdj: return software.vdjStatus
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
    case software(SoftwareDeck)

    var id: String {
        switch self {
        case .denon(let deck, let device):
            if device.isDenonSimulator {
                return DeckDisplayBuilder.testDenonID(deck.id - 1)
            }
            return "denon-\(device.id)-\(deck.id)"
        case .pioneer(let device): return "pioneer-\(device.id)"
        case .pioneerTest: return DeckDisplayBuilder.testPioneerID
        case .denonTest(let layer): return DeckDisplayBuilder.testDenonID(layer)
        case .software(let deck): return deck.id
        }
    }

    var labelKey: String {
        switch self {
        case .denon(let deck, let device):
            if device.isDenonSimulator {
                return DeckLabelKey.denonTest(deck.id - 1)
            }
            return DeckLabelKey.denon(token: device.token, layer: deck.id)
        case .pioneer(let device):
            return DeckLabelKey.pioneer(ip: device.ip, player: device.playerNumber)
        case .pioneerTest: return DeckLabelKey.pioneerTest
        case .denonTest(let layer): return DeckLabelKey.denonTest(layer)
        case .software(let deck): return DeckLabelKey.software(deck.id)
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
        let overlay = testLink.roster.denonOn && device.isDenonSimulator
            ? testLink.snapshot?.deck(deck.id - 1) : nil
        let display = denonDisplay(overlay: overlay)
        let ltcID = device.isDenonSimulator
            ? DeckDisplayBuilder.testDenonID(deck.id - 1)
            : display.id
        PlayerDeckRow(
            deck: display,
            isLarge: isLarge,
            isHero: isHero,
            isLTCSource: outputs.isRowLTCLit(ltcID),
            isMasterFocus: outputs.isMasterFocus(ltcID),
            isLocked: outputs.isDeckLocked(ltcID),
            isHot: outputs.isWaveformHot(ltcID),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(ltcID) },
            onPinMaster: {
                outputs.pinMaster(to: ltcID)
                onFocusMaster()
            },
            onToggleLock: { outputs.toggleDeckLock(ltcID) }
        )
    }

    private func denonDisplay(overlay: TestLinkDeck?) -> DeckDisplay {
        var display = DeckDisplayBuilder.row(
            for: deck, device: device, overlay: overlay
        )
        let ltcID = device.isDenonSimulator
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
            isLocked: outputs.isDeckLocked(display.id),
            isHot: outputs.isWaveformHot(display.id),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(display.id) },
            onPinMaster: {
                outputs.pinMaster(to: display.id)
                onFocusMaster()
            },
            onToggleLock: { outputs.toggleDeckLock(display.id) }
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
            isLocked: outputs.isDeckLocked(display.id),
            isHot: outputs.isWaveformHot(display.id),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(display.id) },
            onPinMaster: {
                outputs.pinMaster(to: display.id)
                onFocusMaster()
            },
            onToggleLock: { outputs.toggleDeckLock(display.id) }
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
            isLocked: outputs.isDeckLocked(display.id),
            isHot: outputs.isWaveformHot(display.id),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(display.id) },
            onPinMaster: {
                outputs.pinMaster(to: display.id)
                onFocusMaster()
            },
            onToggleLock: { outputs.toggleDeckLock(display.id) }
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

struct SoftwareDeckRow: View {
    @ObservedObject var deck: SoftwareDeck
    var isLarge: Bool = true
    var isHero: Bool = false
    var onFocusMaster: () -> Void = {}
    @EnvironmentObject var outputs: OutputController

    var body: some View {
        let display = softwareDisplay
        PlayerDeckRow(
            deck: display,
            isLarge: isLarge,
            isHero: isHero,
            isLTCSource: outputs.isRowLTCLit(display.id),
            isMasterFocus: outputs.isMasterFocus(display.id),
            isLocked: outputs.isDeckLocked(display.id),
            isHot: outputs.isWaveformHot(display.id),
            ltcAutoFollow: outputs.ltcAutoFollow,
            onSelectLTC: { outputs.toggleRowLTC(display.id) },
            onPinMaster: {
                outputs.pinMaster(to: display.id)
                onFocusMaster()
            },
            onToggleLock: { outputs.toggleDeckLock(display.id) }
        )
    }

    private var softwareDisplay: DeckDisplay {
        var display = DeckDisplayBuilder.software(deck)
        display.ltcTimecode = outputs.ltcDeckTimecode[display.id]
            ?? (outputs.isRowLTCLit(display.id) && outputs.ltcEnabled
                ? outputs.ltcTimecode
                : nil)
        display.signalAt = deck.lastSeen
        return display
    }
}

// MARK: - Construcción de filas desde cada protocolo

enum DeckDisplayBuilder {
    static let testPioneerID = "pioneer-test"
    static func testDenonID(_ layer: Int) -> String { "denon-test-\(layer)" }

    /// Capa Denon 1–4. A/B en las dos primeras; DECK 3/4 explícitos.
    static func denonLayerCaption(_ deckID: Int) -> String {
        switch deckID {
        case 1: return "A"
        case 2: return "B"
        case 3: return "DECK 3"
        case 4: return "DECK 4"
        default: return "DECK \(deckID)"
        }
    }

    /// Etiqueta de cabina. Nunca «TEST», «SIM» ni el nombre interno del reproductor local.
    static func productDenonLabel(layer: Int) -> String {
        let cap = denonLayerCaption(layer)
        if cap == "A" || cap == "B" { return "SC6000 · DECK \(cap)" }
        return "SC6000 · \(cap)"
    }

    static func productPioneerLabel(player: Int = 2, model: String = "CDJ-3000") -> String {
        "\(displayPioneerModel(model)) · PLAYER \(player)"
    }

    static func testPioneer(overlay: TestLinkDeck?) -> DeckDisplay {
        let title = TrackNaming.cleanTitle(overlay?.title ?? "")
        let loaded = overlay?.loaded == true
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0)
        let playing = overlay?.playing == true
        var display = DeckDisplay(
            id: testPioneerID,
            source: .pioneer,
            label: productPioneerLabel(),
            title: title,
            artist: overlay?.artist ?? "",
            key: MusicalKey.resolved(raw: overlay?.key ?? "", title: title, artist: overlay?.artist ?? ""),
            genre: overlay?.genre ?? "",
            album: overlay?.album ?? "",
            comment: overlay?.comment ?? "",
            bpm: bpm,
            pitchPercent: Self.publishedPitch(overlay?.pitch),
            isPlaying: playing,
            isMaster: overlay?.isMaster == true || playing,
            isOnAir: false,
            isSynced: overlay?.isSync == true,
            loaded: loaded,
            stateLabel: playing ? "Play" : (loaded ? "Pausa" : "Stop"),
            beatInBar: MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm),
            beatPulse: false,
            elapsed: overlay?.position,
            trackLength: overlay?.duration,
            progress: overlay?.progress,
            accent: Theme.cyan,
            cuePositionFraction: overlay?.cueFractions.first,
            loopInFraction: overlay?.loopInFraction,
            loopOutFraction: overlay?.loopOutFraction,
            peaks: overlay?.peaks ?? [],
            peaksLow: overlay?.peaksLow ?? [],
            peaksMid: overlay?.peaksMid ?? [],
            peaksHigh: overlay?.peaksHigh ?? []
        )
        display.extraCueFractions = overlay?.cueFractions ?? []
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
        applyArtwork(&display, overlay: overlay)
        display.labelKey = DeckLabelKey.pioneerTest
        return display
    }

    static func testDenon(layer: Int, overlay: TestLinkDeck?) -> DeckDisplay {
        let title = TrackNaming.cleanTitle(overlay?.title ?? "")
        let loaded = overlay?.loaded == true
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0)
        let playing = overlay?.playing == true
        var display = DeckDisplay(
            id: testDenonID(layer),
            source: .denon,
            label: productDenonLabel(layer: layer + 1),
            title: title,
            artist: overlay?.artist ?? "",
            key: MusicalKey.resolved(raw: overlay?.key ?? "", title: title, artist: overlay?.artist ?? ""),
            genre: overlay?.genre ?? "",
            album: overlay?.album ?? "",
            comment: overlay?.comment ?? "",
            bpm: bpm,
            pitchPercent: Self.publishedPitch(overlay?.pitch),
            isPlaying: playing,
            isMaster: overlay?.isMaster == true,
            isOnAir: false,
            isSynced: overlay?.isSync == true,
            loaded: loaded,
            stateLabel: playing ? "Play" : (loaded ? "Pausa" : "Stop"),
            beatInBar: MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm),
            beatPulse: false,
            elapsed: overlay?.position,
            trackLength: overlay?.duration,
            progress: overlay?.progress,
            accent: Theme.deckAccent(layer),
            cuePositionFraction: overlay?.cueFractions.first,
            loopInFraction: overlay?.loopInFraction,
            loopOutFraction: overlay?.loopOutFraction,
            peaks: overlay?.peaks ?? [],
            peaksLow: overlay?.peaksLow ?? [],
            peaksMid: overlay?.peaksMid ?? [],
            peaksHigh: overlay?.peaksHigh ?? []
        )
        display.extraCueFractions = overlay?.cueFractions ?? []
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
        applyArtwork(&display, overlay: overlay)
        display.labelKey = DeckLabelKey.denonTest(layer)
        return display
    }

    static func row(for deck: DeckState, device: StageLinqDevice, overlay: TestLinkDeck? = nil) -> DeckDisplay {
        let layer = denonLayerCaption(deck.id)
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
            label: device.isDenonSimulator
                ? productDenonLabel(layer: deck.id)
                : "SC6000 · \(Self.displayDeviceName(deviceName)) \(layer)",
            title: title,
            artist: artist,
            key: key,
            genre: {
                if let g = overlay?.genre, !g.isEmpty { return g }
                return deck.genre
            }(),
            album: overlay?.album ?? "",
            comment: overlay?.comment ?? "",
            bpm: bpm,
            pitchPercent: Self.publishedPitch(overlay?.pitch) ?? Self.publishedPitch((deck.speed - 1.0) * 100.0),
            isPlaying: playing,
            isMaster: overlay?.isMaster ?? deck.isMaster,
            isOnAir: overlay != nil ? false : (deck.volume > 0.05),
            isSynced: overlay?.isSync ?? false,
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
            cuePositionFraction: overlay?.cueFractions.first ?? frac(deck.cuePosition, length: length),
            loopInFraction: overlay?.loopInFraction ?? frac(deck.loopInPosition, length: length),
            loopOutFraction: overlay?.loopOutFraction ?? frac(deck.loopOutPosition, length: length),
            peaks: overlay?.peaks ?? [],
            peaksLow: overlay?.peaksLow ?? [],
            peaksMid: overlay?.peaksMid ?? [],
            peaksHigh: overlay?.peaksHigh ?? []
        )
        display.extraCueFractions = overlay?.cueFractions ?? []
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
        applyArtwork(&display, overlay: overlay)
        display.labelKey = device.isDenonSimulator
            ? DeckLabelKey.denonTest(deck.id - 1)
            : DeckLabelKey.denon(token: device.token, layer: deck.id)
        return display
    }

    static func row(for device: ProDJLinkDevice, overlay: TestLinkDeck? = nil) -> DeckDisplay {
        let label = productPioneerLabel(player: Int(device.playerNumber), model: device.model)
        let overlayTitle = overlay?.title ?? ""
        let title = TrackNaming.cleanTitle(overlayTitle.isEmpty ? device.trackTitle : overlayTitle)
        let loaded = overlay?.loaded ?? device.trackLoaded
        let resolvedHead = device.resolvedPlayhead
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0, device.effectiveBPM, device.trackBPM)
        let progress: Double? = {
            if let o = overlay?.progress { return o }
            if device.trackLength > 0, let head = resolvedHead {
                return min(max(head / device.trackLength, 0), 1)
            }
            return nil
        }()
        let length = overlay?.duration ?? (device.trackLength > 0 ? device.trackLength : nil)
        let elapsed = overlay?.position ?? resolvedHead
        let pitch: Double? = {
            if let fromOverlay = Self.publishedPitch(overlay?.pitch) { return fromOverlay }
            return Self.publishedPitch(device.pitchPercent)
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
            genre: {
                if let g = overlay?.genre, !g.isEmpty { return g }
                return device.trackGenre
            }(),
            album: {
                if let a = overlay?.album, !a.isEmpty { return a }
                return device.trackAlbum
            }(),
            comment: {
                if let c = overlay?.comment, !c.isEmpty { return c }
                return device.trackComment
            }(),
            bpm: loaded ? bpm : 0,
            pitchPercent: pitch,
            isPlaying: playing,
            isMaster: overlay?.isMaster ?? (device.trackLoaded && device.isMaster),
            isOnAir: overlay != nil ? false : (device.trackLoaded && device.isOnAir),
            isSynced: overlay?.isSync ?? (device.trackLoaded && device.isSynced),
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
        applyArtwork(&display, overlay: overlay, jpegData: device.artworkJPEG)
        display.labelKey = DeckLabelKey.pioneer(ip: device.ip, player: device.playerNumber)
        if overlay == nil {
            display.trackBPM = device.trackBPM
            display.faderPitchPercent = Self.publishedPitch(device.faderPitchPercent)
            display.playerSlot = device.slotLabel == "—" ? "" : device.slotLabel
        } else if let p = Self.publishedPitch(overlay?.pitch) {
            if overlay?.bpm ?? 0 > 0, abs(p) > 0.01 {
                display.trackBPM = (overlay?.bpm ?? 0) / (1.0 + p / 100.0)
            }
        }
        return display
    }

    static func software(_ deck: SoftwareDeck) -> DeckDisplay {
        let title = TrackNaming.cleanTitle(deck.title)
        let playing = deck.playing
        var display = DeckDisplay(
            id: deck.id,
            source: deck.kind == .serato ? .serato : .virtualdj,
            label: deck.shortName,
            title: title,
            artist: deck.artist,
            key: "",
            genre: "",
            album: "",
            comment: "",
            bpm: deck.bpm,
            pitchPercent: nil,
            isPlaying: playing,
            isMaster: false,
            isOnAir: false,
            isSynced: false,
            loaded: deck.loaded,
            stateLabel: playing ? "Play" : (deck.loaded ? "Pausa" : "Stop"),
            beatInBar: MusicalClock.beatInBar(position: deck.position, bpm: deck.bpm),
            beatPulse: false,
            elapsed: deck.position,
            trackLength: nil,
            progress: nil,
            accent: deck.kind == .serato ? Theme.ledGreen : Theme.purple,
            cuePositionFraction: nil,
            loopInFraction: nil,
            loopOutFraction: nil
        )
        display.signalAt = deck.lastSeen
        display.controlStamp = controlStamp(
            playing: playing,
            master: false,
            loaded: deck.loaded,
            state: playing ? "Play" : "Pausa",
            title: title,
            key: "",
            jog: playing ? 0 : Int(deck.position * 8)
        )
        display.labelKey = DeckLabelKey.software(deck.id)
        return display
    }

    private static var artByPath: [String: NSImage] = [:]
    private static var artByJPEG: [String: NSImage] = [:]

    private static func jpegCacheKey(_ b64: String) -> String {
        "\(b64.count):\(b64.prefix(24)):\(b64.suffix(16))"
    }

    private static func evictArtCache() {
        if artByPath.count > 24 {
            artByPath.removeAll(keepingCapacity: true)
        }
        if artByJPEG.count > 24 {
            artByJPEG.removeAll(keepingCapacity: true)
        }
    }

    /// TEST: ruta en Application Support / Shared, o JPEG base64 de TestLink.
    /// Pioneer real: JPEG de dbserver GetArtwork si el CDJ lo mandó.
    static func applyArtwork(_ display: inout DeckDisplay, overlay: TestLinkDeck?, jpegData: Data? = nil) {
        if let path = overlay?.artworkPath, !path.isEmpty {
            if let cached = artByPath[path] {
                display.artworkImage = cached
                return
            }
            if let img = NSImage(contentsOfFile: path), img.size.width > 0, img.size.height > 0 {
                artByPath[path] = img
                display.artworkImage = img
                evictArtCache()
                return
            }
        }
        if let b64 = overlay?.artworkJPEG, !b64.isEmpty {
            let key = jpegCacheKey(b64)
            if let cached = artByJPEG[key] {
                display.artworkImage = cached
                return
            }
            if let data = Data(base64Encoded: b64), let img = NSImage(data: data),
               img.size.width > 0, img.size.height > 0 {
                artByJPEG[key] = img
                display.artworkImage = img
                evictArtCache()
                return
            }
        }
        if let data = jpegData, !data.isEmpty {
            let key = "bin:\(data.count):\(data.prefix(12).map { String(format: "%02x", $0) }.joined())"
            if let cached = artByJPEG[key] {
                display.artworkImage = cached
                return
            }
            if let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 {
                artByJPEG[key] = img
                display.artworkImage = img
                evictArtCache()
            }
        }
    }

    static func displayDeviceName(_ raw: String) -> String {
        if StageLinqDevice.isDenonSimulatorName(raw) { return "SC6000" }
        let u = raw.uppercased()
        if u.contains("SC6000-SIM") || u.contains("SC6000 TEST") || u == "TEST" { return "SC6000" }
        return raw
    }

    static func displayPioneerModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = trimmed.uppercased()
        if trimmed.isEmpty || u.contains("TEST") || u.contains("SIM") { return "CDJ-3000" }
        return trimmed
    }

    /// Solo si hay dato real. No se inventa 0 %.
    static func publishedPitch(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, abs(raw) > 0.01 else { return nil }
        return raw
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
