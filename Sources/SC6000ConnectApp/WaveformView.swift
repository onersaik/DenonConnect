// WaveformView.swift
// Waveform RGB estilo CDJ/SC6000: barras con tres bandas de color superpuestas
// (graves=rojo, medios=verde, agudos=cian), mayor resolución, marcador de cue
// naranja y región de loop verde semitransparente.
//
// Sin audio real del dispositivo, las bandas se generan proceduralmente con
// sinusoides de diferente frecuencia: la misma pista siempre produce el mismo
// patrón visual y se desplaza suavemente con la aguja real del deck.

import SwiftUI

struct WaveformView: View {
    let progress:    Double        // 0-1 posición en la pista
    let trackLength: Double?       // segundos totales (nil → 300s asumido)
    let bpm:         Double
    let beatInBar:   Int           // 1-4 beat actual
    let isPlaying:   Bool
    let accent:      Color
    let trackSeed:   Int           // hash del título: patrón consistente por pista

    // Marcadores (opcionales)
    var cuePositionFraction: Double? = nil  // 0…1 posición del cue
    var loopInFraction:  Double? = nil      // 0…1 inicio del loop
    var loopOutFraction: Double? = nil      // 0…1 fin del loop

    // Resolución: barras a cada lado del playhead
    private let halfBars = 110
    private var totalBars: Int { halfBars * 2 + 1 }

    // Barras por beat (zoom)
    private let barsPerBeat: Double = 4.0

    var body: some View {
        Canvas { ctx, size in
            drawWaveform(ctx: ctx, size: size)
        }
        .frame(height: 56)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(edgeFade)
    }

    // MARK: - Render principal

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        let barW    = size.width / CGFloat(totalBars)
        let midX    = size.width / 2.0
        let midY    = size.height / 2.0

        let effectiveBPM = bpm > 20 ? bpm : 120.0
        let length       = trackLength.flatMap { $0 > 0 ? $0 : nil } ?? 300.0
        let totalBeats   = length * effectiveBPM / 60.0
        let currentBeat  = progress * totalBeats

        // ── Región de loop (debajo de las barras) ──────────────────────────
        if let loopIn = loopInFraction, let loopOut = loopOutFraction, loopIn < loopOut {
            let loopInBeat  = loopIn  * totalBeats
            let loopOutBeat = loopOut * totalBeats
            let x1 = xForBeat(loopInBeat,  current: currentBeat, barW: barW, halfBars: halfBars, size: size)
            let x2 = xForBeat(loopOutBeat, current: currentBeat, barW: barW, halfBars: halfBars, size: size)
            if x2 > x1 {
                let loopRect = CGRect(x: x1, y: 0, width: x2 - x1, height: size.height)
                ctx.fill(Path(loopRect), with: .color(Color.green.opacity(0.18)))
                // bordes del loop
                ctx.fill(Path(CGRect(x: x1, y: 0, width: 1.5, height: size.height)), with: .color(Color.green.opacity(0.80)))
                ctx.fill(Path(CGRect(x: x2 - 1.5, y: 0, width: 1.5, height: size.height)), with: .color(Color.green.opacity(0.80)))
            }
        }

        // ── Barras RGB ─────────────────────────────────────────────────────
        for i in 0..<totalBars {
            let offset  = Double(i - halfBars)
            let beatPos = currentBeat + offset / barsPerBeat
            let x       = CGFloat(i) * barW + barW / 2.0
            let isPast  = offset < 0
            let normDist = abs(offset) / Double(halfBars)
            let isCurrent = i == halfBars

            // Tres bandas de frecuencia procedurales
            let bass = bandHeight(beat: beatPos, seed: trackSeed, freqA: 0.50, freqB: 1.03, phaseA: 0.017, phaseB: 0.031)
            let mid  = bandHeight(beat: beatPos, seed: trackSeed, freqA: 2.13, freqB: 3.07, phaseA: 0.011, phaseB: 0.019)
            let hi   = bandHeight(beat: beatPos, seed: trackSeed, freqA: 4.27, freqB: 6.11, phaseA: 0.007, phaseB: 0.009)

            let totalH = size.height * 0.90
            let bassH  = CGFloat(bass) * totalH * 0.50   // graves ocupan la mitad inferior
            let midH   = CGFloat(mid)  * totalH * 0.35
            let hiH    = CGFloat(hi)   * totalH * 0.25

            let fade: Double = isCurrent ? 1.0 : (isPast ? (0.55 + (1 - normDist) * 0.45) : (0.15 + (1 - normDist) * 0.30))
            let bw   = barW * 0.82
            let bx   = x - bw / 2.0

            // Graves (rojo) — base centrada
            let bassRect = CGRect(x: bx, y: midY - bassH / 2, width: bw, height: bassH)
            ctx.fill(Path(roundedRect: bassRect, cornerRadius: 1.0),
                     with: .color(Color(red: 1, green: 0.18, blue: 0.18).opacity(fade * 0.85)))

            // Medios (verde) — superpuesto, más estrecho
            let midRect  = CGRect(x: bx + bw * 0.10, y: midY - midH / 2, width: bw * 0.80, height: midH)
            ctx.fill(Path(roundedRect: midRect, cornerRadius: 0.8),
                     with: .color(Color(red: 0.18, green: 1, blue: 0.35).opacity(fade * 0.75)))

            // Agudos (cian) — más estrecho aún, sólo picos
            let hiRect   = CGRect(x: bx + bw * 0.22, y: midY - hiH / 2, width: bw * 0.56, height: hiH)
            ctx.fill(Path(roundedRect: hiRect, cornerRadius: 0.7),
                     with: .color(Color(red: 0.15, green: 0.90, blue: 1.00).opacity(fade * 0.65)))

            // Rayita de downbeat (cada 4 beats)
            let beatMod4   = beatPos.truncatingRemainder(dividingBy: 4.0)
            let isDownbeat = beatMod4 >= 0 && beatMod4 < (1.0 / barsPerBeat)
            if isDownbeat && !isCurrent {
                let tickH: CGFloat = 6
                let tick = CGRect(x: x - 0.5, y: size.height - tickH, width: 1, height: tickH)
                ctx.fill(Path(tick), with: .color(Color.white.opacity(isPast ? 0.50 : 0.22)))
            }
        }

        // ── Línea del playhead ─────────────────────────────────────────────
        var ph = Path()
        ph.move(to:    CGPoint(x: midX, y: 0))
        ph.addLine(to: CGPoint(x: midX, y: size.height))
        ctx.stroke(ph, with: .color(.white.opacity(0.92)), lineWidth: 1.5)

        // Triángulo superior
        let tri = Path { p in
            p.move(to:    CGPoint(x: midX - 5, y: 0))
            p.addLine(to: CGPoint(x: midX + 5, y: 0))
            p.addLine(to: CGPoint(x: midX,     y: 8))
            p.closeSubpath()
        }
        ctx.fill(tri, with: .color(.white))

        // ── Marcador de cue (naranja) ──────────────────────────────────────
        if let cueFrac = cuePositionFraction {
            let cueBeat = cueFrac * totalBeats
            let cx = xForBeat(cueBeat, current: currentBeat, barW: barW, halfBars: halfBars, size: size)
            if cx >= 0 && cx <= size.width {
                var cp = Path()
                cp.move(to:    CGPoint(x: cx, y: 0))
                cp.addLine(to: CGPoint(x: cx, y: size.height))
                ctx.stroke(cp, with: .color(Color.orange.opacity(0.90)), lineWidth: 2)
                // Pequeño marcador triangular superior
                let ct = Path { p in
                    p.move(to:    CGPoint(x: cx - 5, y: 0))
                    p.addLine(to: CGPoint(x: cx + 5, y: 0))
                    p.addLine(to: CGPoint(x: cx,     y: 7))
                    p.closeSubpath()
                }
                ctx.fill(ct, with: .color(Color.orange))
            }
        }
    }

    // MARK: - Helpers

    /// Convierte una posición en beats a coordenada X en la vista.
    private func xForBeat(_ beat: Double, current: Double, barW: CGFloat, halfBars: Int, size: CGSize) -> CGFloat {
        let offset = (beat - current) * barsPerBeat
        let barIndex = Double(halfBars) + offset
        return CGFloat(barIndex) * barW + barW / 2.0
    }

    /// Altura de una banda de frecuencia determinista en [0.06, 1].
    private func bandHeight(beat: Double, seed: Int, freqA: Double, freqB: Double, phaseA: Double, phaseB: Double) -> Double {
        let s = Double(abs(seed % 997) + 1)
        let a = abs(sin(beat * freqA + s * phaseA)) * 0.55
        let b = abs(sin(beat * freqB + s * phaseB)) * 0.35
        let c = abs(sin(beat * (freqA + freqB) * 0.5 + s * (phaseA + phaseB))) * 0.10
        return min(1.0, max(0.06, a + b + c))
    }

    // MARK: - Gradientes laterales

    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(0.60), .clear],
                           startPoint: .leading, endPoint: .trailing).frame(width: 36)
            Spacer()
            LinearGradient(colors: [.clear, Color.black.opacity(0.60)],
                           startPoint: .leading, endPoint: .trailing).frame(width: 36)
        }
        .allowsHitTesting(false)
    }
}
