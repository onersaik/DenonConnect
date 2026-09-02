// OutputsView.swift
// Panel de salidas hacia otras aplicaciones: OSC a Resolume y SMPTE LTC.

import SwiftUI
import StageLinqKit

struct OutputsView: View {
    @EnvironmentObject var outputs: OutputController
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.panelBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    clockSection
                    resolumeSection
                    ltcSection
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 560)
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Text("SALIDAS")
                .font(.system(size: 13, weight: .bold))
                .tracking(1.0)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button("Cerrar") { presentation.wrappedValue.dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(16)
        .background(Theme.panel)
    }

    // MARK: Reloj

    private var clockSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("RELOJ DE REFERENCIA")
            HStack(spacing: 10) {
                Text(outputs.clockSource)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.ledGreen)
                Text(outputs.clockBPM > 0 ? String(format: "%.2f BPM", outputs.clockBPM) : "sin señal")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
            Text("Se usa el deck marcado como master; si no hay ninguno, el primero que esté sonando.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Resolume

    private var resolumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("RESOLUME (OSC)")

            Text("Resolume no permite que otra app se le conecte como si fuera un reproductor: su soporte de StageLinq y Pro DJ Link escucha directamente a los equipos. Lo que sí expone para control externo es OSC, y por ahí le pasamos tempo y compás.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("En Resolume: Preferencias → OSC → activar entrada.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            HStack(spacing: 8) {
                LabeledField(label: "Host", text: $outputs.resolumeHost, width: 150)
                LabeledField(label: "Puerto", text: $outputs.resolumePort, width: 80)
            }

            Picker("Modo", selection: $outputs.resolumeTempoMode) {
                ForEach(ResolumeBridge.TempoMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Enviar resync en el primer tiempo del compás", isOn: $outputs.resolumeResync)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)

            Text("Si el tempo no entra, prueba el modo «Tap por beat»: las direcciones OSC de tempo cambian entre versiones de Resolume.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ActionButton(title: outputs.resolumeEnabled ? "DETENER" : "ACTIVAR",
                             active: outputs.resolumeEnabled,
                             color: Theme.accent) {
                    outputs.toggleResolume()
                }
                if outputs.resolumeEnabled {
                    Button("Aplicar cambios") { outputs.applyResolumeSettings() }
                        .font(.system(size: 11))
                }
            }
        }
        .padding(14)
        .panelStyle(cornerRadius: 10)
    }

    // MARK: SMPTE

    private var ltcSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("SMPTE LTC POR AUDIO")

            Text("Genera timecode SMPTE como señal de audio a partir de la posición del deck. Sirve para cualquier app o mesa que acepte timecode por audio.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Timecode grande
            Text(outputs.ltcTimecode)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundColor(outputs.ltcEnabled ? Theme.ledGreen : Theme.textTertiary.opacity(0.5))

            // Frame rate
            HStack(spacing: 8) {
                Text("Frame rate")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                Picker("", selection: $outputs.ltcFrameRate) {
                    ForEach(LTCGenerator.FrameRate.allCases, id: \.self) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(outputs.ltcEnabled)
            }

            // Selector de dispositivo de salida
            VStack(alignment: .leading, spacing: 4) {
                Text("CANAL DE SALIDA")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(Theme.textTertiary)

                Picker("", selection: $outputs.ltcSelectedDeviceID) {
                    ForEach(outputs.ltcDevices) { device in
                        HStack(spacing: 5) {
                            if device.isDefault && device.id == 0 {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 9))
                            } else if device.isDefault {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                            }
                            Text(device.name)
                        }
                        .tag(device.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(outputs.ltcEnabled)
                .font(.system(size: 11))

                Text("BlackHole o Loopback para enviar a otra app; salida física para otra máquina. ★ = por defecto del sistema.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !outputs.ltcError.isEmpty {
                Text(outputs.ltcError)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.red)
            }

            HStack(spacing: 8) {
                ActionButton(title: outputs.ltcEnabled ? "DETENER" : "ACTIVAR",
                             active: outputs.ltcEnabled,
                             color: Theme.cyan) {
                    outputs.toggleLTC()
                }
                // Refrescar lista de dispositivos si se conecta algo nuevo
                if !outputs.ltcEnabled {
                    Button("↻ Actualizar") { outputs.refreshLTCDevices() }
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(14)
        .panelStyle(cornerRadius: 10)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundColor(Theme.textSecondary)
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(Theme.textTertiary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: width)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let active: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundColor(active ? Theme.red : color)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((active ? Theme.red : color).opacity(0.15))
                )
        }
        .buttonStyle(.plain)
    }
}
