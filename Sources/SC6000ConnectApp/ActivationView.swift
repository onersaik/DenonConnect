// ActivationView.swift
// Pantalla de primer arranque: pide la clave antes de usar la app.

import SwiftUI

struct ActivationView: View {
    @EnvironmentObject var license: LicenseStore
    @State private var code = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 18) {
                Text("STAGE CONNECT")
                    .font(.system(size: 16, weight: .bold))
                    .tracking(2.0)
                    .foregroundColor(Theme.textPrimary)

                Text("Activación")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)

                Text("Introduce la clave de activación para usar la app.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)

                SecureField("Clave", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(Theme.overlay(0.06))
                    .overlay(Rectangle().stroke(Theme.panelBorder, lineWidth: 1))
                    .onSubmit { submit() }

                if !license.lastError.isEmpty {
                    Text(license.lastError)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.red)
                }

                Button(action: submit) {
                    Text("ACTIVAR")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                        .background(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(28)
            .frame(width: 380)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.panelBorder, lineWidth: 1))
        }
    }

    private func submit() {
        _ = license.activate(code: code)
    }
}
