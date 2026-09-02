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
    @Environment(\.presentationMode) private var presentation

    @State private var section: SettingsSection = .ltc
    @State private var showExportSuccess = false

    enum SettingsSection: String, CaseIterable {
        case ltc     = "LTC"
        case mtc     = "MTC"
        case osc     = "OSC"
        case web     = "Web"
        case history = "Historial"

        var icon: String {
            switch self {
            case .ltc:     return "waveform.path"
            case .mtc:     return "pianokeys"
            case .osc:     return "wifi"
            case .web:     return "globe"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().background(Theme.panelBorder)
            content
        }
        .frame(width: 640, height: 560)
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
                Text("AJUSTES")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(Theme.textPrimary)
                Text("SC6000 Connect")
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
                if s == .ltc && outputs.ltcEnabled   { dot(Theme.cyan) }
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
                case .history: historySection
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: LTC

    private var ltcSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "waveform.path", title: "SMPTE LTC por audio",
                          subtitle: "Genera timecode como señal de audio. Usa BlackHole o Loopback para enviarlo a otra app; salida física para sincronizar con otro equipo.")

            // Timecode display
            Text(outputs.ltcTimecode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(outputs.ltcEnabled ? Theme.ledGreen : Theme.textTertiary.opacity(0.4))

            settingsPanel {
                // Frame rate
                labelRow(label: "Frame rate") {
                    Picker("", selection: $outputs.ltcFrameRate) {
                        ForEach(LTCGenerator.FrameRate.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(outputs.ltcEnabled)
                    .frame(width: 210)
                    .labelsHidden()
                }

                Divider().background(Theme.panelBorder)

                // Dispositivo de salida
                labelRow(label: "Salida de audio") {
                    Picker("", selection: $outputs.ltcSelectedDeviceID) {
                        ForEach(outputs.ltcDevices) { dev in
                            Text(dev.name).tag(dev.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(outputs.ltcEnabled)
                    .font(.system(size: 11))
                    .frame(maxWidth: 210)
                    .labelsHidden()
                }
            }

            if !outputs.ltcError.isEmpty {
                errorBanner(outputs.ltcError)
            }

            HStack(spacing: 8) {
                toggleButton(label: outputs.ltcEnabled ? "Detener" : "Activar",
                             active: outputs.ltcEnabled, color: Theme.cyan) {
                    outputs.toggleLTC()
                }
                if !outputs.ltcEnabled {
                    refreshButton { outputs.refreshLTCDevices() }
                }
                Spacer()
                openAudioMIDIButton
            }
        }
    }

    // MARK: MTC

    private var mtcSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "pianokeys", title: "MIDI Timecode (MTC)",
                          subtitle: "Crea el puerto virtual MIDI 'SC6000 Connect MTC' en el sistema. Cualquier DAW o software que acepte MTC externo puede suscribirse a él.")

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

            Text("El puerto aparece en Audio MIDI Setup -> Studio MIDI -> SC6000 Connect MTC.")
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
                          subtitle: "Monitoriza los decks desde cualquier navegador en la misma red. Abre http://[IP del Mac]:[puerto] en tu telefono o tablet.")

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
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.ledGreen)
                        .font(.system(size: 11))
                    Text("Activo en http://localhost:\(outputs.webPort)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.ledGreen)
                }
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

    // MARK: Historial

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "clock.arrow.circlepath", title: "Historial de reproducción",
                          subtitle: "Registro automático de cada pista que suena. Exporta como CSV para playlists, royalties o análisis.")

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
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
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

    private func exportCSV() {
        let csv = outputs.exportHistoryCSV()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SC6000-historial-\(formattedDate()).csv"
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
