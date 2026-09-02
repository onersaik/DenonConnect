// WaveformView.swift
// Waveform estilo ShowKontrol: scrolling desde el playhead real, colores por
// zona (pasado / presente / futuro) y marcadores de beat y downbeat.
//
// Sin transferencia de audio real del dispositivo generamos un patrón
// determinista con múltiples sinusoides: el mismo título siempre produce la
// misma forma, y el patrón desplaza suavemente según la posición real de la
// aguja del deck.

import SwiftUI

struct WaveformView: View {
    let progress: Double        // 0-1 posición en la pista
    let trackLength: Double?    // segundos totales (nil → 300s asumido)
    let bpm: Double             // para escalar el zoom en beats
    let beatInBar: Int          // 1-4 beat actual (para pulso visual)
    let isPlaying: Bool
    let accent: Color
    let trackSeed: Int          // hash del título: patrón consistente por pista

    // Barras a cada lado del playhead central
    private let halfBars = 52
    private var totalBars: Int { halfBars * 2 + 1 }

    // Barras por beat (zoom fijo): 4 → ~12 beats visibles a ambos lados
    private let barsPerBeat: Double = 4.0

    var body: some View {
        Canvas { ctx, size in
            let barW    = size.width / CGFloat(totalBars)
            let midX    = size.width / 2.0
            let midY    = size.height / 2.0

            let effectiveBPM = bpm > 20 ? bpm : 120.0
            let length       = trackLength.flatMap { $0 > 0 ? $0 : nil } ?? 300.0
            let totalBeats   = length * effectiveBPM / 60.0
            let currentBeat  = progress * totalBeats

            for i in 0..<totalBars {
                let offset  = Double(i - halfBars)
                let beatPos = currentBeat + offset / barsPerBeat

                // Altura procedural determinista (siempre positiva, 0.06…1)
                let h    = barHeight(beat: beatPos, seed: trackSeed)
                let barH = h * size.height * 0.88

                // ¿Es downbeat? (cada 4 beats)
                let beatMod4   = beatPos.truncatingRemainder(dividingBy: 4.0)
                let isDownbeat = beatMod4 >= 0 && beatMod4 < (1.0 / barsPerBeat)
                let isOnBeat   = beatPos.truncatingRemainder(dividingBy: 1.0) < (1.0 / barsPerBeat)

                // Color según zona
                let isCurrent = i == halfBars
                let isPast    = offset < 0
                let normDist  = abs(offset) / Double(halfBars) // 0..1

                let color: Color
                if isCurrent {
                    color = .white
                } else if isPast {
                    // Pasado: más brillante cerca del playhead, se apaga hacia la izq
                    let fade = 1.0 - normDist
                    color = isDownbeat
                        ? accent.opacity(0.70 + fade * 0.25)
                        : accent.opacity(0.30 + fade * 0.50)
                } else {
                    // Futuro: más tenue
                    let fade = 1.0 - normDist
                    color = isDownbeat
                        ? accent.opacity(0.35 + fade * 0.20)
                        : accent.opacity(0.10 + fade * 0.22)
                }

                let x    = CGFloat(i) * barW + barW / 2.0
                let rect = CGRect(
                    x:      x - barW * 0.40,
                    y:      midY - barH / 2.0,
                    width:  barW * 0.80,
                    height: barH
                )
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(color))

                // Rayita fina de beat en la parte inferior
                if (isOnBeat || isDownbeat) && !isCurrent {
                    let tickH: CGFloat = isDownbeat ? 6 : 3
                    let tick = CGRect(x: x - 0.5, y: size.height - tickH, width: 1, height: tickH)
                    let tickColor = isDownbeat
                        ? Color.white.opacity(isPast ? 0.45 : 0.20)
                        : Color.white.opacity(isPast ? 0.20 : 0.10)
                    ctx.fill(Path(tick), with: .color(tickColor))
                }
            }

            // Línea vertical del playhead
            var ph = Path()
            ph.move(to:    CGPoint(x: midX, y: 0))
            ph.addLine(to: CGPoint(x: midX, y: size.height))
            ctx.stroke(ph, with: .color(.white.opacity(0.90)), lineWidth: 1.5)

            // Triángulo superior del playhead
            let tri = Path { p in
                p.move(to:    CGPoint(x: midX - 5, y: 0))
                p.addLine(to: CGPoint(x: midX + 5, y: 0))
                p.addLine(to: CGPoint(x: midX,     y: 8))
                p.closeSubpath()
            }
            ctx.fill(tri, with: .color(.white))
        }
        .frame(height: 56)
        .background(Color.black.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            // Gradientes laterales para fundir los bordes
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.55), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 40)
                Spacer()
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.55)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 40)
            }
            .allowsHitTesting(false)
        )
    }

    // MARK: Patrón determinista

    /// Combina cuatro sinusoides con frecuencias y fases derivadas de `seed`.
    /// Devuelve un valor en [0.06, 1.0] para que no haya barras invisibles.
    private func barHeight(beat: Double, seed: Int) -> Double {
        let s = Double(abs(seed % 997) + 1)
        let a = abs(sin(beat * 1.000 + s * 0.031)) * 0.44
        let b = abs(sin(beat * 2.137 + s * 0.017)) * 0.28
        let c = abs(sin(beat * 4.271 + s * 0.009)) * 0.16
        let d = abs(sin(beat * 0.317 + s * 0.053)) * 0.12
        return min(1.0, max(0.06, a + b + c + d))
    }
}
