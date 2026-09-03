// OutputsView.swift
// Panel de ajustes completo: salidas de timecode (LTC, MTC), OSC, servidor web,
// historial de reproducción y utilidades del sistema.

import SwiftUI
import AppKit
import CoreAudio
import UniformTypeIdentifiers
import StageLinqKit

struct OutputsView: View {
    @EnvironmentObject var outputs: OutputController
    @EnvironmentObject var license: LicenseStore
    @EnvironmentObject var mapping: MappingController
    @EnvironmentObject var labels: DeckLabelStore
    @EnvironmentObject var software: SoftwareDJManager
    @Environment(\.presentationMode) private var presentation
    @Environment(\.openWindow) private var openWindow

    @State private var section: SettingsSection = .ltc
    @State private var showExportSuccess = false

    enum SettingsSection: String, CaseIterable {
        case ltc     = "LTC"
        case mtc     = "MTC"
        case osc     = "OSC"
        case web     = "Web"
        case obs     = "OBS"
        case history = "Historial"
        case labels   = "Etiquetas"
        case mapping = "Mapeo"
        case license = "Licencia"

        var icon: String {
            switch self {
            case .ltc:     return "waveform.path"
            case .mtc:     return "pianokeys"
            case .osc:     return "wifi"
            case .web:     return "globe"
            case .obs:     return "video"
            case .history: return "clock.arrow.circlepath"
            case .labels:  return "tag"
            case .mapping: return "keyboard"
            case .license: return "key.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().background(Theme.panelBorder)
            content
        }
        .frame(width: 680, height: 680)
        .background(Theme.background)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.accent)
                Text("CONFIG")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(Theme.textPrimary)
                Text("AJUSTES")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                Text("STAGE CONNECT")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(18)

            Divider().background(Theme.panelBorder)

            ForEach(SettingsSection.allCases, id: \.self) { s in
                sidebarRow(s)
            }

            Spacer()

            // Reloj de referencia en la parte inferior
            clockWidget
        }
        .frame(width: 170)
        .background(Theme.panel)
    }

    private func sidebarRow(_ s: SettingsSection) -> some View {
        let active = section == s
        return Button { section = s } label: {
            HStack(spacing: 10) {
                Image(systemName: s.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundColor(active ? Theme.accent : Theme.textSecondary)
                Text(s.rawValue)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                // Indicador activo
                if s == .ltc && outputs.ltcAnyEnabled { dot(Theme.cyan) }
                if s == .mtc && outputs.mtcEnabled   { dot(Theme.purple) }
                if s == .osc && outputs.resolumeEnabled { dot(Theme.accent) }
                if s == .web && outputs.webEnabled   { dot(Theme.ledGreen) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(active ? Color.white.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }

    private var clockWidget: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().background(Theme.panelBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("RELOJ")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(Theme.textTertiary)
                Text(outputs.clockSource)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.ledGreen)
                    .lineLimit(1)
                Text(outputs.clockBPM > 0
                     ? String(format: "%.2f BPM", outputs.clockBPM)
                     : "sin señal")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: Contenido

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch section {
                case .ltc:     ltcSection
                case .mtc:     mtcSection
                case .osc:     oscSection
                case .web:     webSection
                case .obs:     obsSection
                case .history: historySection
                case .labels:  labelsSection
                case .mapping: mappingSection
                case .license: licenseSection
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: LTC

    private var ltcSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "waveform.path", title: "SMPTE LTC",
                          subtitle: "MASTER es el LTC de casa: un generador, una salida, sigue al deck master / On Air / el que suena. LOCK en una fila con salida propia ancla ese generador; el master no lo pisa y puede ir a otro deck. SMPTE de fila enciende el LTC de esa pista.")

            Text(outputs.ltcTimecode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(outputs.ltcEnabled ? Theme.ledGreen : Theme.textTertiary.opacity(0.4))

            Text("MASTER DE CASA")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.textTertiary)

            Button {
                if outputs.ltcEnabled { outputs.stopMasterLTC() }
                else { outputs.enableMasterAutoFollow() }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(outputs.ltcEnabled ? Theme.ledGreen : Theme.textTertiary.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .shadow(color: outputs.ltcEnabled ? Theme.ledGreen.opacity(0.8) : .clear, radius: 4)
                    Text(outputs.ltcEnabled ? "MASTER ON" : "MASTER OFF")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.6)
                    Spacer()
                    Text(outputs.ltcEnabled ? (outputs.ltcAutoFollow ? "sigue fader" : "anclado") : "apagado")
                        .font(.system(size: 10))
                        .foregroundColor(outputs.ltcEnabled ? Theme.textSecondary : Theme.textTertiary)
                }
                .foregroundColor(outputs.ltcEnabled ? .black : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Rectangle().fill(outputs.ltcEnabled ? Theme.ledGreen : Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)

            settingsPanel {
                labelRow(label: "Auto (fader)") {
                    Toggle("", isOn: Binding(
                        get: { outputs.ltcAutoFollow },
                        set: { outputs.setAutoFollow($0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                }
                Divider().background(Theme.panelBorder)
                labelRow(label: "Frame rate") {
                    Picker("", selection: $outputs.ltcFrameRate) {
                        ForEach(LTCGenerator.FrameRate.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .labelsHidden()
                    .onChange(of: outputs.ltcFrameRate) { _ in
                        outputs.applyMasterFrameRateChange()
                    }
                }
                Divider().background(Theme.panelBorder)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Salidas Master")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Elige una o varias. El mismo TC se duplica en cada device. Si otro LTC usa el mismo canal, avisa.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                    deviceChecklist(slot: "master", selected: outputs.masterDeviceIDs) { id in
                        outputs.toggleMasterDevice(id)
                    }
                }
            }

            Text("El MASTER salta al playhead del nuevo deck (LED Master, On Air o fader), no reinicia el reloj. Play 1×, pausa congela, seek salta. LOCK + salida separada: esa fila sigue su playhead; el master va a otro deck.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("POR REPRODUCTOR")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.textTertiary)
                .padding(.top, 4)

            Text("Cada fila puede tener su generador y su dispositivo. Dos LTC en el mismo canal se pisan: Master en una salida, decks locked en otras (BlackHole / Loopback / interfaz). LOCK impide que el auto-follow del MASTER pise esa salida.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if outputs.ltcDeckSlots.isEmpty {
                Text("No hay reproductores visibles. Carga una pista para asignar salidas.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            } else {
                settingsPanel {
                    ForEach(Array(outputs.ltcDeckSlots.enumerated()), id: \.element.id) { index, slot in
                        if index > 0 { Divider().background(Theme.panelBorder) }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { outputs.isDeckLTCEnabled(slot.id) },
                                    set: { outputs.setDeckLTCEnabled(slot.id, enabled: $0) }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                Text(slot.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Button {
                                    outputs.toggleDeckLock(slot.id)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: outputs.isDeckLocked(slot.id) ? "lock.fill" : "lock.open")
                                            .font(.system(size: 8))
                                        Text("LOCK")
                                            .font(.system(size: 8, weight: .bold))
                                    }
                                    .foregroundColor(outputs.isDeckLocked(slot.id) ? .black : Theme.textTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Rectangle().fill(outputs.isDeckLocked(slot.id) ? Theme.yellow : Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .help("Con salida separada, el MASTER no pisa este generador.")
                                Spacer()
                                Text(outputs.ltcDeckTimecode[slot.id] ?? "00:00:00:00")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(outputs.isDeckLTCEnabled(slot.id) ? Theme.ledGreen : Theme.textTertiary)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Salidas")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                                deviceChecklist(slot: slot.id, selected: outputs.deckDeviceIDs(slot.id)) { id in
                                    outputs.toggleDeckDevice(slot.id, deviceID: id)
                                }
                            }
                            HStack {
                                Text("TC / Frame rate")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(width: 110, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { outputs.ltcDeckFrameRates[slot.id] ?? outputs.ltcFrameRate },
                                    set: { outputs.setDeckFrameRate(slot.id, rate: $0) }
                                )) {
                                    ForEach(LTCGenerator.FrameRate.allCases, id: \.self) { r in
                                        Text(r.label).tag(r)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 210)
                                .labelsHidden()
                                Spacer()
                            }
                            if let err = outputs.ltcDeckError[slot.id], !err.isEmpty {
                                Text(err)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !outputs.ltcDeviceWarning.isEmpty {
                errorBanner(outputs.ltcDeviceWarning)
            }
            if !outputs.ltcError.isEmpty {
                errorBanner(outputs.ltcError)
            }

            HStack(spacing: 8) {
                toggleButton(label: outputs.ltcEnabled ? "Detener Master" : "Activar Master",
                             active: outputs.ltcEnabled, color: Theme.cyan) {
                    outputs.toggleLTC()
                }
                refreshButton { outputs.refreshLTCDevices() }
                Spacer()
                openAudioMIDIButton
            }
        }
    }

    // MARK: MTC

    private var mtcSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "pianokeys", title: "MIDI Timecode (MTC)",
                          subtitle: "Crea el puerto virtual MIDI 'STAGE CONNECT MTC' en el sistema. Cualquier DAW o software que acepte MTC externo puede suscribirse a él.")

            settingsPanel {
                labelRow(label: "Frame rate") {
                    Picker("", selection: $outputs.mtcFrameRate) {
                        ForEach(MIDITimecodeGenerator.FrameRate.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(outputs.mtcEnabled)
                    .frame(width: 210)
                    .labelsHidden()
                }
            }

            Text("El puerto aparece en Audio MIDI Setup -> Studio MIDI -> STAGE CONNECT MTC.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !outputs.mtcError.isEmpty {
                errorBanner(outputs.mtcError)
            }

            HStack(spacing: 8) {
                toggleButton(label: outputs.mtcEnabled ? "Detener" : "Activar",
                             active: outputs.mtcEnabled, color: Theme.purple) {
                    outputs.toggleMTC()
                }
                Spacer()
                openAudioMIDIButton
            }
        }
    }

    // MARK: OSC / Resolume

    private var oscSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "wifi", title: "OSC a Resolume",
                          subtitle: "Envía tempo y compás a Resolume Arena/Avenue. En Resolume: Preferencias -> OSC -> Activar entrada.")

            settingsPanel {
                labelRow(label: "Host") {
                    TextField("", text: $outputs.resolumeHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 150)
                }
                Divider().background(Theme.panelBorder)
                labelRow(label: "Puerto") {
                    TextField("", text: $outputs.resolumePort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 80)
                }
                Divider().background(Theme.panelBorder)
                labelRow(label: "Modo") {
                    Picker("", selection: $outputs.resolumeTempoMode) {
                        ForEach(ResolumeBridge.TempoMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .labelsHidden()
                }
                Divider().background(Theme.panelBorder)
                labelRow(label: "Resync downbeat") {
                    Toggle("", isOn: $outputs.resolumeResync)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
            }

            Text("Si el tempo no entra, prueba el modo 'Tap por beat': las rutas OSC cambian entre versiones de Resolume.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                toggleButton(label: outputs.resolumeEnabled ? "Detener" : "Activar",
                             active: outputs.resolumeEnabled, color: Theme.accent) {
                    outputs.toggleResolume()
                }
                if outputs.resolumeEnabled {
                    Button("Aplicar cambios") { outputs.applyResolumeSettings() }
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Web Server

    private var webSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "globe", title: "Servidor web",
                          subtitle: "Monitor en el navegador, JSON y WebSocket para un overlay propio (Resolume, OBS). No es un bot de Twitch.")

            settingsPanel {
                labelRow(label: "Puerto") {
                    TextField("", text: $outputs.webPort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 80)
                        .disabled(outputs.webEnabled)
                }
            }

            if outputs.webEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.ledGreen)
                            .font(.system(size: 11))
                        Text("Activo en http://localhost:\(outputs.webPort)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.ledGreen)
                    }
                    Text("JSON  /api    SSE  /events    WebSocket  /ws    OBS  /obs    iPad  /monitor")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                    Text("iPad: \(NetworkInfo.describe(NetworkInfo.localIPv4Bytes())):\(outputs.webPort)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.cyan)
                }
            } else {
                Text("GET /api  ·  SSE /events  ·  WebSocket /ws  (mismo JSON: título, artista, bpm, playhead, playing)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }

            if !outputs.webError.isEmpty {
                errorBanner(outputs.webError)
            }

            toggleButton(label: outputs.webEnabled ? "Detener" : "Activar",
                         active: outputs.webEnabled, color: Theme.ledGreen) {
                outputs.toggleWebServer()
            }
        }
    }

    // MARK: OBS

    private var obsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "video", title: "OBS Browser Source",
                          subtitle: "Añade un Browser Source 1920×1080. El overlay pinta el TC y los decks. No es un bot de Twitch.")

            settingsPanel {
                labelRow(label: "Fondo") {
                    Toggle("Transparente", isOn: $outputs.obsTransparent)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
            }

            if outputs.webEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("En este Mac")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundColor(Theme.textTertiary)
                    urlCopyRow(outputs.obsURL(lan: false), hint: "URL local copiada")
                    Text("En la red (otro equipo)")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundColor(Theme.textTertiary)
                    urlCopyRow(outputs.obsURL(lan: true), hint: "URL de red copiada")
                    if !outputs.copiedHint.isEmpty {
                        Text(outputs.copiedHint)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.ledGreen)
                    }
                }
            } else {
                Text("Activa el servidor web para obtener la URL. OBS: Browser Source, 1920×1080, FPS 30.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                toggleButton(label: "Activar servidor web",
                             active: false, color: Theme.ledGreen) {
                    outputs.toggleWebServer()
                }
            }

            if !outputs.webError.isEmpty {
                errorBanner(outputs.webError)
            }
        }
    }

    private func urlCopyRow(_ url: String, hint: String) -> some View {
        HStack(spacing: 8) {
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.cyan)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Button("Copiar") {
                outputs.copyToPasteboard(url, hint: hint)
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func deviceChecklist(slot: String, selected: [AudioDeviceID], toggle: @escaping (AudioDeviceID) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(outputs.ltcDevices) { dev in
                let on = selected.contains(dev.id)
                let owners = outputs.conflictOwners(for: dev.id, excluding: slot)
                Button { toggle(dev.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .foregroundColor(on ? Theme.ledGreen : Theme.textTertiary)
                        Text(dev.name)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textPrimary)
                        if !owners.isEmpty {
                            Text("también: \(owners.joined(separator: ", "))")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.yellow)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            if outputs.ltcDevices.isEmpty {
                Text("No hay salidas de audio. Abre Audio MIDI Setup o pulsa actualizar.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    // MARK: Historial

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "clock.arrow.circlepath", title: "Historial de reproducción",
                          subtitle: "Se guarda solo cuando un deck en play cambia de título. JSON y TXT en la carpeta que elijas.")

            settingsPanel {
                labelRow(label: "Auto-guardar") {
                    Toggle("", isOn: Binding(
                        get: { outputs.historyAutoSave },
                        set: { on in
                            outputs.historyAutoSave = on
                            if on { outputs.persistHistory() }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                }
                Divider().background(Theme.panelBorder)
                labelRow(label: "Carpeta") {
                    Text(outputs.historyFolderURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }

            HStack(spacing: 8) {
                Button {
                    chooseHistoryFolder()
                } label: {
                    Label("Elegir carpeta", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)

                Button {
                    try? FileManager.default.createDirectory(
                        at: outputs.historyFolderURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(outputs.historyFolderURL)
                } label: {
                    Label("Abrir carpeta", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    exportCSV()
                } label: {
                    Label("Exportar CSV", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .disabled(outputs.playlistHistory.isEmpty)

                Button {
                    outputs.clearHistory()
                } label: {
                    Label("Limpiar", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .disabled(outputs.playlistHistory.isEmpty)

                if showExportSuccess {
                    Text("CSV guardado")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.ledGreen)
                }

                Spacer()
                Text("\(outputs.playlistHistory.count) pistas")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }

            if outputs.playlistHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("El historial se llena automáticamente cuando suenan pistas.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(outputs.playlistHistory) { entry in
                        HStack(spacing: 10) {
                            Text(entry.formattedTime)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title.isEmpty ? "—" : entry.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                if !entry.artist.isEmpty {
                                    Text(entry.artist)
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(entry.source)
                                .font(.system(size: 9))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(6)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: Etiquetas + monitor

    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "tag", title: "Etiquetas de decks",
                          subtitle: "Letra, número o nombre visible en la tira. Clic en la etiqueta de cada fila o edita aquí. Se guarda en este Mac.")

            Button {
                openWindow(id: "sc-monitor")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "display")
                    Text("Abrir MONITOR")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("TC + decks  ·  F pantalla completa")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                .foregroundColor(Theme.textPrimary)
                .padding(12)
                .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Ventana aparte para llevar a otro monitor. Fondo negro.")

            Button {
                openWindow(id: "sc-tracklist")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Abrir SETLIST")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("pegar / importar / historial")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                .foregroundColor(Theme.textPrimary)
                .padding(12)
                .background(Rectangle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Lista de concierto en ventana aparte.")

            settingsPanel {
                if labels.sortedKeys.isEmpty {
                    Text("Ninguna etiqueta personalizada. Clic en A/1 de una fila para cambiarla.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                } else {
                    ForEach(labels.sortedKeys, id: \.self) { key in
                        HStack {
                            Text(key)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .lineLimit(1)
                            Spacer()
                            TextField("A", text: Binding(
                                get: { labels.tag(for: key) ?? "" },
                                set: { labels.setTag($0, for: key) }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .frame(width: 90)
                            .padding(6)
                            .background(Color.black)
                            Button("X") { labels.clear(key) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("Borrar todas") { labels.clearAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.yellow)
                        .padding(.top, 8)
                }
            }

            settingsPanel {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SOFTWARE DJ")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundColor(Theme.textTertiary)
                    Text(software.seratoStatus)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text(software.vdjStatus)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text("Serato: anuncio Bonjour _SeratoIOSRemote; abre Serato DJ Pro en este Mac. VirtualDJ: Extensions → Network Control en localhost (8080/80).")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: Mapeo MIDI / teclado

    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "keyboard", title: "Mapeo",
                          subtitle: "Teclado y MIDI se encienden o se apagan por separado. Off = no disparan. Note on o CC>64 = toggle. CC 0 = off. No se dispara al escribir en un campo.")

            HStack(spacing: 8) {
                mapMasterSwitch(title: "TECLADO", on: mapping.keyboardEnabled) {
                    mapping.keyboardEnabled.toggle()
                }
                mapMasterSwitch(title: "MIDI", on: mapping.midiEnabled) {
                    mapping.midiEnabled.toggle()
                }
            }

            settingsPanel {
                labelRow(label: "Puerto MIDI") {
                    Picker("", selection: Binding(
                        get: { mapping.selectedSourceID },
                        set: { mapping.selectSource($0) }
                    )) {
                        Text("Primer dispositivo").tag("")
                        ForEach(mapping.sources) { src in
                            Text(src.name).tag(src.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 11))
                    .frame(maxWidth: 240)
                    .labelsHidden()
                    .disabled(!mapping.midiEnabled)
                }
                Divider().background(Theme.panelBorder)
                Text(mapping.midiEnabled ? mapping.midiStatus : "MIDI apagado. No se leen CC ni notas.")
                    .font(.system(size: 10))
                    .foregroundColor(mapping.midiEnabled ? Theme.textTertiary : Theme.yellow)
                    .padding(.vertical, 6)
                if mapping.midiEnabled, !mapping.lastMIDILabel.isEmpty {
                    Text("Ultimo: \(mapping.lastMIDILabel)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.ledGreen)
                        .padding(.bottom, 4)
                }
                HStack(spacing: 8) {
                    Button("Actualizar puertos") {
                        mapping.refreshSources()
                        mapping.reconnectMIDI()
                    }
                    .font(.system(size: 11))
                    Button("Reset") {
                        mapping.resetToDefaults()
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    Spacer()
                    openAudioMIDIButton
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)
            }

            Text("STAGE CONNECT MTC es salida de timecode, no se usa para mapear.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)

            Text("F1–F4 son las primeras 4 filas visibles (SMPTE). LOCK/SMPTE van por id de fila, no por posición en CONFIG. Dual admite 8 filas (4 CDJ + 4 capas Denon).")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(groupedActions, id: \.title) { group in
                Text(group.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(group.title == "Master" ? Theme.ledGreen : Theme.textTertiary)
                    .padding(.top, 4)
                settingsPanel {
                    ForEach(Array(group.actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { Divider().background(Theme.panelBorder) }
                        mappingRow(action)
                    }
                }
            }
        }
        .onAppear {
            mapping.refreshSources()
            mapping.reconnectMIDI()
        }
    }

    private func mapMasterSwitch(title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(on ? Theme.ledGreen : Theme.textTertiary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .shadow(color: on ? Theme.ledGreen.opacity(0.8) : .clear, radius: 3)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.7)
                Spacer()
                Text(on ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
            }
            .foregroundColor(on ? Theme.ledGreen : Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Rectangle().fill(Color.white.opacity(on ? 0.10 : 0.05)))
            .overlay(Rectangle().stroke(on ? Theme.ledGreen.opacity(0.35) : Theme.panelBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var groupedActions: [(title: String, actions: [MappingAction])] {
        let groups = ["Master", "Vistas", "SMPTE", "LOCK", "Salidas"]
        return groups.map { title in
            (title, MappingAction.allCases.filter { $0.group == title })
        }
    }

    private func mappingRow(_ action: MappingAction) -> some View {
        let learningMIDI = mapping.learning == .midi(action)
        let learningKey = mapping.learning == .key(action)
        let extra: String = {
            switch action {
            case .toggleRow1SMPTE, .toggleRow1Lock: return mapping.rowLabel(0)
            case .toggleRow2SMPTE, .toggleRow2Lock: return mapping.rowLabel(1)
            case .toggleRow3SMPTE, .toggleRow3Lock: return mapping.rowLabel(2)
            case .toggleRow4SMPTE, .toggleRow4Lock: return mapping.rowLabel(3)
            default: return ""
            }
        }()
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 11, weight: action.group == "Master" ? .semibold : .medium))
                    .foregroundColor(Theme.textPrimary)
                if !extra.isEmpty {
                    Text(extra)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .frame(minWidth: 148, alignment: .leading)
            Text(mapping.keyBindings[action]?.label ?? "—")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(mapping.keyboardEnabled ? Theme.cyan : Theme.textTertiary)
                .frame(width: 36, alignment: .center)
            Text(mapping.midiBindings[action]?.label ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(mapping.midiBindings[action] == nil ? Theme.textTertiary : Theme.ledGreen)
                .lineLimit(1)
                .frame(minWidth: 72, alignment: .leading)
            Spacer(minLength: 4)
            Button(learningKey ? "…" : "TECLA") {
                if learningKey { mapping.cancelLearn() }
                else { mapping.beginLearnKey(action) }
            }
            .foregroundColor(learningKey ? Theme.accent : Theme.textSecondary)
            Button(learningMIDI ? "…" : "MIDI") {
                if learningMIDI { mapping.cancelLearn() }
                else { mapping.beginLearnMIDI(action) }
            }
            .foregroundColor(learningMIDI ? Theme.accent : Theme.textSecondary)
            if mapping.keyBindings[action] != nil {
                Button("X") { mapping.clearKey(action) }
                    .foregroundColor(Theme.textTertiary)
                    .help("Quitar tecla")
            }
            if mapping.midiBindings[action] != nil {
                Button("X") { mapping.clearMIDI(action) }
                    .foregroundColor(Theme.textTertiary)
                    .help("Quitar MIDI")
            }
        }
        .font(.system(size: 10))
        .buttonStyle(.plain)
        .padding(.vertical, 5)
    }

    // MARK: Licencia

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "key.fill", title: "Licencia",
                          subtitle: "Activa la app con una clave mensual o vitalicia. Puedes quitarla en cualquier momento; al hacerlo se pide de nuevo al abrir. Las claves no se muestran aquí.")

            settingsPanel {
                labelRow(label: "Estado") {
                    Text(license.statusText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(license.isUnlocked ? Theme.ledGreen : Theme.red)
                }
            }

            if license.isUnlocked {
                Button {
                    license.deactivate()
                    presentation.wrappedValue.dismiss()
                } label: {
                    Text("QUITAR LICENCIA")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundColor(Theme.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.red.opacity(0.12))
                }
                .buttonStyle(.plain)
                .help("Borra la clave de este Mac. La próxima vez que abras la app pedirá activación.")
            }
        }
    }

    // MARK: Helpers de UI

    private func sectionHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()
                Button("Cerrar") { presentation.wrappedValue.dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func settingsPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14)
        .background(
            Rectangle()
                .fill(Theme.panel)
                .overlay(
                    Rectangle()
                        .stroke(Theme.panelBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func labelRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 110, alignment: .leading)
            content()
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func toggleButton(label: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? color : Theme.textTertiary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(active ? color : Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill((active ? color : Theme.textTertiary).opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    private func refreshButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help("Actualizar lista de dispositivos de audio")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.red)
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(Theme.red)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.red.opacity(0.08)))
    }

    private var openAudioMIDIButton: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        } label: {
            Label("Audio MIDI Setup", systemImage: "slider.horizontal.3")
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Abre Audio MIDI Setup de macOS para configurar el enrutado de audio")
    }

    private func chooseHistoryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputs.historyFolderURL
        panel.prompt = "Elegir"
        panel.message = "Carpeta para historial.json e historial.txt"
        if panel.runModal() == .OK, let url = panel.url {
            outputs.historyFolderPath = url.path
            outputs.persistHistory()
        }
    }

    private func exportCSV() {
        let csv = outputs.exportHistoryCSV()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "STAGE-CONNECT-historial-\(formattedDate()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
            showExportSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showExportSuccess = false
            }
        }
    }

    private func formattedDate() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
}
