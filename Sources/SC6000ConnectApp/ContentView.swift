// ContentView.swift
// Ventana principal: barra lateral de dispositivos + grid 2x2 de decks + log.

import SwiftUI
import StageLinqKit

struct ContentView: View {
    @EnvironmentObject var manager: StageLinqManager
    @State private var selectedDeviceID: String?
    @State private var showLog = false

    private var selectedDevice: StageLinqDevice? {
        if let id = selectedDeviceID, let d = manager.devices.first(where: { $0.id == id }) {
            return d
        }
        return manager.devices.first
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selectedDeviceID: $selectedDeviceID)
                .frame(width: 260)
                .background(Theme.panel)

            Divider().background(Theme.panelBorder)

            VStack(spacing: 0) {
                HeaderBar(device: selectedDevice, showLog: $showLog)

                if let device = selectedDevice {
                    DeckGridView(device: device)
                        .padding(16)
                } else {
                    EmptyStateView()
                }

                Divider().background(Theme.panelBorder)
                CDJStripView()

                if showLog {
                    Divider().background(Theme.panelBorder)
                    LogView()
                        .frame(height: 160)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .background(Theme.background)
    }
}

private struct HeaderBar: View {
    let device: StageLinqDevice?
    @Binding var showLog: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device?.name.isEmpty == false ? device!.name : "SC6000 Connect")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let device {
                    HStack(spacing: 6) {
                        StatusDot(state: device.connectionState)
                        Text(statusText(device.connectionState))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                        if device.masterTempo > 0 {
                            Text("· Master \(device.masterTempo, specifier: "%.1f") BPM")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
            }
            Spacer()
            Button {
                showLog.toggle()
            } label: {
                Label(showLog ? "Ocultar log" : "Ver log", systemImage: "terminal")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    func statusText(_ state: StageLinqDevice.ConnectionState) -> String {
        switch state {
        case .discovered: return "Descubierto"
        case .connecting: return "Conectando…"
        case .connected: return "Conectado"
        case .failed: return "Error de conexión"
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundColor(Theme.textTertiary)
            Text("Buscando SC6000 en la red…")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Asegúrate de que tus SC6000 y este Mac están\nen el mismo switch o red WiFi.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusDot: View {
    let state: StageLinqDevice.ConnectionState
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: state == .connected ? 4 : 0)
    }
    var color: Color {
        switch state {
        case .discovered: return Theme.textTertiary
        case .connecting: return Theme.yellow
        case .connected: return Theme.green
        case .failed: return Theme.red
        }
    }
}

private struct DeckGridView: View {
    @ObservedObject var device: StageLinqDevice

    let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    let names = ["DECK 1 · A", "DECK 1 · B", "DECK 2 · A", "DECK 2 · B"]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(0..<4, id: \.self) { i in
                DeckCardView(deck: device.decks[i], title: names[i], accent: Theme.deckAccent(i))
            }
        }
    }
}
