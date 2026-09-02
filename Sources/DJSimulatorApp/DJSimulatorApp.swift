// DJSimulatorApp.swift
// App independiente que finge ser un reproductor en la red, para comprobar
// que SC6000 Connect descubre, conecta y pinta los datos sin tener el equipo
// delante. Se ejecuta a la vez que la app principal, en el mismo Mac.

import SwiftUI
import StageLinqKit

@main
struct DJSimulatorApp: App {
    @StateObject private var controller = SimulatorController()

    var body: some Scene {
        WindowGroup("Simulador de reproductores") {
            SimulatorView()
                .environmentObject(controller)
                .frame(minWidth: 520, minHeight: 420)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

final class SimulatorController: ObservableObject {
    @Published var denonRunning = false
    @Published var pioneerRunning = false
    @Published var logLines: [String] = []

    private var denon: DenonSimulator?
    private var pioneer: PioneerSimulator?

    func log(_ message: String) {
        DispatchQueue.main.async {
            self.logLines.append(message)
            if self.logLines.count > 300 {
                self.logLines.removeFirst(self.logLines.count - 300)
            }
        }
    }

    func toggleDenon() {
        if denonRunning {
            denon?.stop()
            denon = nil
            denonRunning = false
        } else {
            let sim = DenonSimulator(log: { [weak self] in self?.log($0) })
            denon = sim
            sim.start()
            denonRunning = true
        }
    }

    func togglePioneer() {
        if pioneerRunning {
            pioneer?.stop()
            pioneer = nil
            pioneerRunning = false
        } else {
            let sim = PioneerSimulator(log: { [weak self] in self?.log($0) })
            pioneer = sim
            sim.start()
            pioneerRunning = true
        }
    }
}

struct SimulatorView: View {
    @EnvironmentObject var controller: SimulatorController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SIMULADOR DE REPRODUCTORES")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1.0)
                Text("Finge ser un SC6000 y un CDJ-3000 en la red, para probar SC6000 Connect sin el equipo.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)

            Divider()

            HStack(spacing: 12) {
                SimulatorButton(
                    title: "Denon SC6000",
                    subtitle: "StageLinq · 2 decks con pista",
                    running: controller.denonRunning,
                    color: .orange
                ) {
                    controller.toggleDenon()
                }

                SimulatorButton(
                    title: "Pioneer CDJ-3000",
                    subtitle: "Pro DJ Link · player 2",
                    running: controller.pioneerRunning,
                    color: .cyan
                ) {
                    controller.togglePioneer()
                }
            }
            .padding(18)

            Divider()

            Text("REGISTRO")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
            }

            Divider()

            Text("Arranca aquí un simulador y abre SC6000 Connect: debería aparecer solo.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(14)
        }
    }
}

private struct SimulatorButton: View {
    let title: String
    let subtitle: String
    let running: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(running ? color : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(running ? "DETENER" : "ARRANCAR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(running ? .red : color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(running ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(running ? color.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
