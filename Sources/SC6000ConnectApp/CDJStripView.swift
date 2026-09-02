// CDJStripView.swift
// Franja inferior con el estado en vivo de los reproductores Pioneer/AlphaTheta
// (CDJ-3000 y compatibles) detectados por Pro DJ Link.

import SwiftUI
import StageLinqKit

struct CDJStripView: View {
    @EnvironmentObject var proDJLink: ProDJLinkManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.cyan)
                Text("CDJ · PRO DJ LINK")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(Theme.textSecondary)
                Text("\(proDJLink.devices.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
            }

            if proDJLink.devices.isEmpty {
                Text("Buscando CDJ en la red…")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.vertical, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(proDJLink.devices) { device in
                            CDJCardView(device: device)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct CDJCardView: View {
    @ObservedObject var device: ProDJLinkDevice

    private var accent: Color {
        Theme.deckAccent((device.playerNumber - 1 + 4) % 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(device.isPlaying ? accent : Theme.textTertiary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text("PLAYER \(device.playerNumber)")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 8)
                if device.isMaster {
                    Text("MASTER")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.accent)
                }
                CDJBeatDot(pulse: device.beatPulse, active: device.isPlaying, accent: accent)
            }

            Text(device.model.isEmpty ? "CDJ" : device.model)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)

            HStack(spacing: 14) {
                CDJMetric(value: device.effectiveBPM > 0 ? String(format: "%.2f", device.effectiveBPM) : "—", label: "BPM", color: Theme.cyan)
                CDJMetric(value: String(format: "%+.2f%%", device.pitchPercent), label: "PITCH", color: Theme.purple)
                CDJMetric(value: device.beatInBar > 0 ? "\(device.beatInBar)/4" : "—", label: "BEAT", color: Theme.yellow)
            }

            HStack(spacing: 6) {
                CDJTag(text: device.playModeLabel, color: device.isPlaying ? Theme.green : Theme.textTertiary)
                if device.isOnAir { CDJTag(text: "ON AIR", color: Theme.red) }
                if device.isSynced { CDJTag(text: "SYNC", color: Theme.cyan) }
                if device.trackLoaded { CDJTag(text: device.slotLabel, color: Theme.textSecondary) }
            }

            if !device.hasStatus {
                Text("Solo presencia — sin estado detallado todavía")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .panelStyle(cornerRadius: 10)
    }
}

private struct CDJMetric: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .tracking(0.5)
                .foregroundColor(color)
        }
    }
}

private struct CDJTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
    }
}

private struct CDJBeatDot: View {
    let pulse: Bool
    let active: Bool
    let accent: Color
    @State private var flash = false

    var body: some View {
        Circle()
            .fill(active ? accent : Theme.textTertiary.opacity(0.3))
            .frame(width: 7, height: 7)
            .scaleEffect(flash ? 1.7 : 1.0)
            .animation(.easeOut(duration: 0.15), value: flash)
            .onChange(of: pulse) { _ in
                guard active else { return }
                flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { flash = false }
            }
    }
}
