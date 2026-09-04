// ActivationView.swift
// Pantalla de primer arranque: pide la clave antes de usar la app.

import SwiftUI

struct ActivationView: View {
    @EnvironmentObject var license: LicenseStore
    @State private var code = ""
    @State private var mostrarAyuda = false

    private var codigoVacio: Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()

            VStack(spacing: 0) {
                // Cabecera
                VStack(spacing: 6) {
                    Text("STAGE CONNECT")
                        .font(.system(size: 15, weight: .bold))
                        .tracking(2.4)
                        .foregroundColor(Theme.textPrimary)
                        .noClip()
                    Text("ACTIVACIÓN")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.6)
                        .foregroundColor(Theme.accent)
                        .noClip()
                }
                .padding(.bottom, 22)

                Text("Introduce la clave que recibiste al adquirir la licencia.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 18)

                // Campo
                TextField("SCL-XXXX-XXXX-XXXXX", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.textPrimary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(Theme.overlay(0.06))
                    .overlay(
                        Rectangle().stroke(
                            license.lastError.isEmpty ? Theme.panelBorder : Theme.red.opacity(0.6),
                            lineWidth: 1
                        )
                    )
                    .disabled(license.isChecking)
                    .onSubmit(activar)

                // Mensaje de error
                if !license.lastError.isEmpty {
                    Text(license.lastError)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }

                // Boton
                Button(action: activar) {
                    HStack(spacing: 8) {
                        if license.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .colorInvert()
                        }
                        Text(license.isChecking ? "COMPROBANDO" : "ACTIVAR")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .noClip()
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background((codigoVacio || license.isChecking) ? Theme.accent.opacity(0.4) : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(codigoVacio || license.isChecking)
                .padding(.top, 18)

                // Ayuda
                Button {
                    mostrarAyuda.toggle()
                } label: {
                    Text(mostrarAyuda ? "Ocultar ayuda" : "No puedo activar")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textTertiary)
                        .underline()
                        .noClip()
                }
                .buttonStyle(.plain)
                .padding(.top, 14)

                if mostrarAyuda {
                    VStack(alignment: .leading, spacing: 9) {
                        ayuda("Las claves SCL necesitan internet una sola vez. Después la app funciona sin red.")
                        ayuda("En cabina, sin servidor: clave del instalador o emergencia. Si Express corre en este Mac (:3000), las SCL también se canjean en local aunque app.entikmedia.com no resuelva.")
                        ayuda("Si la clave SCL ya está en otro equipo, libéralo desde ese Mac o escríbenos para desvincularlo.")

                        Text("info@entikmedia.com")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(Theme.accent)
                            .padding(.top, 3)
                            .noClip()
                    }
                    .padding(.top, 14)
                    .transition(.opacity)
                }

                Text("ENTIK MEDIA")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 22)
                    .noClip()
            }
            .padding(30)
            .frame(width: 400)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.panelBorder, lineWidth: 1))
            .animation(.easeInOut(duration: 0.18), value: mostrarAyuda)
            .animation(.easeInOut(duration: 0.18), value: license.isChecking)
        }
    }

    private func ayuda(_ texto: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("·")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.accent)
            Text(texto)
                .font(.system(size: 10.5))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activar() {
        guard !codigoVacio, !license.isChecking else { return }
        license.activate(code: code) { ok in
            if ok { code = "" }
        }
    }
}
