// SidebarView.swift
// Lista de dispositivos StageLinq descubiertos, con indicador de estado.

import SwiftUI
import StageLinqKit

struct SidebarView: View {
    @EnvironmentObject var manager: StageLinqManager
    @Binding var selectedDeviceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "opticaldisc.fill")
                    .foregroundColor(Theme.accent)
                Text("Dispositivos")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(manager.devices.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider().background(Theme.panelBorder)

            if manager.devices.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("Buscando…")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(manager.devices) { device in
                            DeviceRow(device: device, isSelected: isSelected(device))
                                .onTapGesture { selectedDeviceID = device.id }
                        }
                    }
                    .padding(8)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Text("StageLinq · UDP \(StageLinq.listenPort)")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
                Text("SC6000 Connect — no oficial")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(14)
        }
    }

    private func isSelected(_ device: StageLinqDevice) -> Bool {
        if let sel = selectedDeviceID { return sel == device.id }
        return manager.devices.first?.id == device.id
    }
}

private struct DeviceRow: View {
    @ObservedObject var device: StageLinqDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: device.connectionState)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name.isEmpty ? device.ip : device.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(device.source) · v\(device.version)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.accentDim : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
