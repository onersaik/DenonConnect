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
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var localization: LocalizationStore
    @EnvironmentObject var updates: AppUpdateStore
    @Environment(\.presentationMode) private var presentation
    @Environment(\.openWindow) private var openWindow

    @State private var section: SettingsSection = .ltc
    @State private var showExportSuccess = false

    enum SettingsSection: String, CaseIterable {
        case sources = "Fuentes"
        case ltc     = "LTC"
        case mtc     = "MTC"
        case osc     = "OSC"
        case web     = "Web"
        case obs     = "OBS"
        case history = "Historial"
        case labels   = "Etiquetas"
        case mapping = "Mapeo"
        case updates    = "Actualizaciones"
        case license    = "Licencia"
        case language   = "Idioma"
        case appearance = "Apariencia"

        var icon: String {
            switch self {
            case .sources: return "checklist"
            case .ltc:     return "waveform.path"
            case .mtc:     return "pianokeys"
            case .osc:     return "wifi"
            case .web:     return "globe"
            case .obs:     return "video"
            case .history: return "clock.arrow.circlepath"
            case .labels:  return "tag"
            case .mapping: return "keyboard"
            case .updates:    return "arrow.down.circle"
            case .license:    return "key.fill"
            case .language:   return "globe"
            case .appearance: return "circle.lefthalf.filled"
            }
        }

        var locKey: String {
            switch self {
            case .sources: return "settings.sources"
            case .ltc: return "settings.ltc"
            case .mtc: return "settings.mtc"
            case .osc: return "settings.osc"
            case .web: return "settings.web"
            case .obs: return "settings.obs"
            case .history: return "settings.history"
            case .labels: return "settings.labels"
            case .mapping: return "settings.mapping"
            case .updates: return "settings.updates"
            case .license: return "settings.license"
            case .language: return "settings.language"
            case .appearance: return "settings.appearance"
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
                Text(localization.t("settings.title"))
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(Theme.textPrimary)
                Text(localization.t("settings.subtitle"))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                Text("STAGE CONNECT")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(18)
            .id(localization.language)

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
                Text(localization.t(s.locKey))
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? Theme.textPrimary : Theme.textSecondary)
                    .noClip()
                    .id(localization.language)
                Spacer(minLength: 4)
                // Indicador activo
                if s == .ltc && outputs.ltcAnyEnabled { dot(Theme.cyan) }
                if s == .mtc && outputs.mtcEnabled   { dot(Theme.purple) }
                if s == .osc && outputs.resolumeEnabled { dot(Theme.accent) }
                if s == .web && outputs.webEnabled   { dot(Theme.ledGreen) }
                if s == .updates && updates.hasUpdate { dot(Theme.accent) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(active ? Theme.overlay(0.06) : Color.clear)
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
                Text(localization.t("common.clock"))
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
                case .sources: sourcesSection
                case .ltc:     ltcSection
                case .mtc:     mtcSection
                case .osc:     oscSection
                case .web:     webSection
                case .obs:     obsSection
                case .history: historySection
                case .labels:  labelsSection
                case .mapping: mappingSection
                case .updates:    updatesSection
                case .license:    licenseSection
                case .language:   languageSection
                case .appearance: appearanceSection
                }
            }
            .padding(22)
            .id(localization.language)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Fuentes

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "checklist", title: localization.t("settings.sources"),
                          subtitle: localization.t("settings.sources.subtitle"))

            settingsPanel {
                sourceTick("Denon", isOn: $mapping.sourceDenon)
                sourceTick("Pioneer", isOn: $mapping.sourcePioneer)
                sourceTick("Serato", isOn: $mapping.sourceSerato)
                sourceTick("VDJ", isOn: $mapping.sourceVDJ)
                sourceTick("rekordbox", isOn: $mapping.sourceRekordbox)
                sourceTick("Traktor", isOn: $mapping.sourceTraktor)
                Divider().background(Theme.panelBorder)
                Button {
                    let on = !mapping.allSourcesEnabled
                    mapping.setAllSources(on)
                    if on { mapping.mode = .todos }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mapping.allSourcesEnabled ? "checkmark.square.fill" : "square")
                            .foregroundColor(mapping.allSourcesEnabled ? Theme.ledGreen : Theme.textTertiary)
                        Text(localization.t("settings.sources.all"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            Text(localization.t("settings.sources.hint"))
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceTick(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundColor(isOn.wrappedValue ? Theme.ledGreen : Theme.textTertiary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: LTC

    private var ltcSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "waveform.path", title: localization.t("ltc.title"),
                          subtitle: localization.t("ltc.subtitle"))

            Text(outputs.ltcTimecode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(outputs.ltcEnabled ? Theme.ledGreen : Theme.textTertiary.opacity(0.4))

            Text(localization.t("ltc.master.home"))
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
                .background(Rectangle().fill(outputs.ltcEnabled ? Theme.ledGreen : Theme.overlay(0.07)))
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(localization.t("ltc.network.emergency"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Picker("", selection: $outputs.ltcNetworkLossMode) {
                        ForEach(LTCNetworkLossMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(outputs.ltcNetworkLossMode.help)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    Text(localization.t("ltc.outputs.master"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Text(localization.t("ltc.outputs.hint"))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                    deviceChecklist(slot: "master", selected: outputs.masterDeviceIDs) { id in
                        outputs.toggleMasterDevice(id)
                    }
                }
            }

            Text("El MASTER salta al playhead del nuevo deck (LED Master, On Air o fader), no reinicia el reloj. Play 1×, pausa congela, seek salta en todas las salidas de esa fuente. Si un device se desfasó, el tick unifica. LOCK + salida separada: esa fila sigue su playhead; el master no la pisa.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text(localization.t("ltc.per.player"))
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.textTertiary)
                .padding(.top, 4)

            Text("Cada fila puede tener su generador y su dispositivo. Dos LTC en el mismo canal se pisan: Master en una salida, decks locked en otras (BlackHole / Loopback / interfaz). LOCK impide que el auto-follow del MASTER pise esa salida.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if outputs.ltcDeckSlots.isEmpty {
                Text(localization.t("ltc.no.players"))
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
                                    .background(Rectangle().fill(outputs.isDeckLocked(slot.id) ? Theme.yellow : Theme.overlay(0.08)))
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
            sectionHeader(icon: "pianokeys", title: localization.t("mtc.title"),
                          subtitle: localization.t("mtc.subtitle"))

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

            Text(localization.t("mtc.port.hint"))
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
            sectionHeader(icon: "wifi", title: localization.t("osc.title"),
                          subtitle: localization.t("osc.subtitle"))

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
            sectionHeader(icon: "globe", title: localization.t("web.title"),
                          subtitle: localization.t("web.subtitle"))

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
            sectionHeader(icon: "video", title: localization.t("obs.title.section"),
                          subtitle: localization.t("obs.subtitle"))

            settingsPanel {
                labelRow(label: "Fondo") {
                    Toggle(localization.t("obs.transparent"), isOn: $outputs.obsTransparent)
                        .id(localization.language)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                Divider().background(Theme.panelBorder)
                Text(localization.t("obs.content"))
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundColor(Theme.textTertiary)
                Toggle(localization.t("obs.tc"), isOn: $outputs.obsShowTC)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Toggle(localization.t("obs.title"), isOn: $outputs.obsShowTitle)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Toggle(localization.t("obs.artwork"), isOn: $outputs.obsShowArtwork)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Toggle(localization.t("obs.meta"), isOn: $outputs.obsShowMeta)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Toggle(localization.t("obs.decks"), isOn: $outputs.obsShowDecks)
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
            .id(localization.language)

            if outputs.webEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localization.t("web.on.this.mac"))
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundColor(Theme.textTertiary)
                    urlCopyRow(outputs.obsURL(lan: false), hint: "URL local copiada")
                    Text(localization.t("web.on.lan"))
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
                Text(localization.t("obs.enable.web"))
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
                VStack(alignment: .leading, spacing: 3) {
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
                    if on {
                        HStack(spacing: 8) {
                            Text("Vol")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textTertiary)
                                .frame(width: 28, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(outputs.levelForDevice(dev.id)) },
                                    set: { outputs.setLevelForDevice(dev.id, level: Float($0)) }
                                ),
                                in: 0...1
                            )
                            .controlSize(.small)
                            Text(String(format: "%.0f%%", outputs.levelForDevice(dev.id) * 100))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .padding(.leading, 22)
                    }
                }
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
            sectionHeader(icon: "clock.arrow.circlepath", title: localization.t("history.title"),
                          subtitle: localization.t("history.subtitle"))

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
                    Text(localization.t("history.empty"))
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
                        .background(Theme.overlay(0.03))
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
            sectionHeader(icon: "tag", title: localization.t("labels.title"),
                          subtitle: localization.t("labels.subtitle"))

            Button {
                openWindow(id: "sc-monitor")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "display")
                    Text(localization.t("labels.open.monitor"))
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("TC + decks  ·  F pantalla completa")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                .foregroundColor(Theme.textPrimary)
                .padding(12)
                .background(Rectangle().fill(Theme.overlay(0.07)))
            }
            .buttonStyle(.plain)
            .help("Ventana aparte para llevar a otro monitor. Fondo negro.")

            Button {
                openWindow(id: "sc-tracklist")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                    Text(localization.t("labels.open.setlist"))
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("pegar / importar / historial")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                .foregroundColor(Theme.textPrimary)
                .padding(12)
                .background(Rectangle().fill(Theme.overlay(0.07)))
            }
            .buttonStyle(.plain)
            .help("Lista de concierto en ventana aparte.")

            settingsPanel {
                if labels.sortedKeys.isEmpty {
                    Text(localization.t("labels.empty"))
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
            sectionHeader(icon: "keyboard", title: localization.t("mapping.title"),
                          subtitle: localization.t("mapping.subtitle"))

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
                        Text(localization.t("mapping.first.device")).tag("")
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

            Text(localization.t("mapping.hint.dual"))
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
            .background(Rectangle().fill(Theme.overlay(on ? 0.10 : 0.05)))
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


    // MARK: Idioma

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "globe", title: localization.t("language.title"),
                          subtitle: localization.t("language.select"))

            settingsPanel {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AppLanguage.allCases) { lang in
                        Button {
                            localization.language = lang
                            localization.objectWillChange.send()
                        } label: {
                            HStack(spacing: 10) {
                                Text(lang.flag)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .frame(width: 24)
                                Text(lang.displayName)
                                    .font(.system(size: 12, weight: localization.language == lang ? .semibold : .regular))
                                    .foregroundColor(localization.language == lang ? Theme.textPrimary : Theme.textSecondary)
                                Spacer()
                                if localization.language == lang {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Rectangle()
                                    .fill(localization.language == lang ? Theme.accent.opacity(0.10) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        if lang != AppLanguage.allCases.last {
                            Divider().background(Theme.panelBorder)
                        }
                    }
                }
            }
        }
    }

    // MARK: Apariencia

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "circle.lefthalf.filled", title: localization.t("appearance.title"),
                          subtitle: localization.t("appearance.subtitle"))

            settingsPanel {
                labelRow(label: "Modo") {
                    HStack(spacing: 0) {
                        Button {
                            if !theme.isDark { theme.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "moon.fill")
                                    .font(.system(size: 11))
                                Text(localization.t("appearance.dark.short"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.isDark ? .black : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Rectangle().fill(theme.isDark ? Theme.accent : Theme.buttonBg))
                        }
                        .buttonStyle(.plain)

                        Button {
                            if theme.isDark { theme.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sun.max.fill")
                                    .font(.system(size: 11))
                                Text(localization.t("appearance.light.short"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(!theme.isDark ? .black : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Rectangle().fill(!theme.isDark ? Theme.accent : Theme.buttonBg))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(localization.t("appearance.hint"))
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actualizaciones

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "arrow.down.circle", title: localization.t("updates.title"),
                          subtitle: localization.t("updates.subtitle"))

            settingsPanel {
                labelRow(label: "Version local") {
                    Text("\(AppUpdateStore.currentVersion) (\(AppUpdateStore.currentBuild))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                }
                Divider().background(Theme.panelBorder)
                labelRow(label: "Estado") {
                    Text(updates.statusMessage.isEmpty ? "Sin comprobar" : updates.statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(updates.lastError.isEmpty ? Theme.textSecondary : Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let remote = updates.available {
                    Divider().background(Theme.panelBorder)
                    labelRow(label: "Disponible") {
                        Text("v\(remote.version)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.accent)
                    }
                    if !remote.notes.isEmpty {
                        Divider().background(Theme.panelBorder)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(localization.t("updates.notes"))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                            Text(remote.notes)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    updates.checkForUpdates()
                } label: {
                    HStack(spacing: 6) {
                        if updates.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(updates.isChecking ? "COMPROBANDO…" : "REVISAR SI HAY ACTUALIZACIONES")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                            .noClip()
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Rectangle().fill(Theme.buttonBg))
                }
                .buttonStyle(.plain)
                .disabled(updates.isChecking || updates.isDownloading)

                if updates.hasUpdate {
                    Button {
                        updates.installAvailableUpdate()
                    } label: {
                        HStack(spacing: 6) {
                            if updates.isDownloading {
                                ProgressView()
                                    .controlSize(.small)
                                Text(String(format: "%.0f%%", updates.downloadProgress * 100))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                Text(localization.t("updates.action"))
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(0.6)
                            }
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Rectangle().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(updates.isDownloading)
                    .help("Descarga el build a Descargas y abre Finder")
                }
            }

            Text("Tras descargar: abre el .dmg o descomprime el .zip y sustituye STAGE CONNECT en Aplicaciones. No hace falta cerrar la cabina hasta instalar.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Licencia

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "key.fill", title: localization.t("license.title"),
                          subtitle: localization.t("license.subtitle"))

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
                    Text(localization.t("license.remove"))
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
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.overlay(0.06)))
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
