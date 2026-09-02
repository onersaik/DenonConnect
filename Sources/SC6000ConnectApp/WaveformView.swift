// WaveformView.swift
// Waveform RGB estilo CDJ: graves rojo, medios verde, agudos cian.
// Vista Grande: aguja fija al centro, las barras se desplazan con subpíxel
// (no un scrubber que salta de barra en barra). Peaks reales de TEST si
// existen; si no, patrón procedural estable por trackSeed. Sin reloj 294 s.

import SwiftUI

enum WaveformMode {
    /// Ventana que se desplaza; playhead fijo al centro (vista Grande).
    case scrolling
    /// Toda la pista; playhead en la fracción de progreso (vista Pequeña).
    case overview
}

struct WaveformView: View {
    let progress:    Double?
    let trackLength: Double?
    let bpm:         Double
    let beatInBar:   Int
    let isPlaying:   Bool
    let accent:      Color
    let trackSeed:   Int
    var peaks:       [Float] = []
    var cuePositionFraction: Double? = nil
    var loopInFraction:  Double? = nil
    var loopOutFraction: Double? = nil
    var mode: WaveformMode = .scrolling
    /// Ventana visible en segundos. CDJ ~12 s; vista 4: más zoom en el deck
    /// caliente (~8 s) y más contexto en el resto (~24 s).
    var windowSeconds: Double = 12.0
    private let halfBars = 180
    private var totalBars: Int { halfBars * 2 + 1 }

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black))
            let midY = size.height / 2
            ctx.fill(
                Path(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1)),
                with: .color(accent.opacity(0.16))
            )
            if mode == .overview {
                drawOverview(ctx: ctx, size: size)
            } else {
                drawScrolling(ctx: ctx, size: size)
            }
        }
        .transaction { $0.animation = nil }
        .frame(minHeight: 36)
        .background(Color.black)
    }

    // MARK: - Tiempo real de la pista (nunca 294 / 300 inventados)

    private var elapsedSeconds: Double {
        if let p = progress, let l = trackLength, l > 0, p.isFinite, l.isFinite {
            return min(max(p, 0), 1) * l
        }
        return 0
    }

    private var durationSeconds: Double {
        let l = trackLength ?? 0
        return l > 0 && l.isFinite ? l : 0
    }

    private var hasTimeline: Bool { durationSeconds > 0 && progress != nil }

    // MARK: - Scrolling (CDJ): playhead al centro, scroll subpíxel

    private func drawScrolling(ctx: GraphicsContext, size: CGSize) {
        let barW = size.width / CGFloat(totalBars)
        let midX = size.width / 2
        let midY = size.height / 2
        let maxH = size.height * 0.92
        let elapsed = elapsedSeconds
        let duration = durationSeconds
        let secPerBar = windowSeconds / Double(totalBars)

        // Desplazamiento fraccionario: las barras se mueven de verdad, no saltan.
        let exact = elapsed / secPerBar
        let frac = exact - floor(exact)
        let shift = CGFloat(frac) * barW

        drawLoopScrolling(ctx: ctx, size: size, elapsed: elapsed, secPerBar: secPerBar, shift: shift, barW: barW)

        for i in 0..<(totalBars + 1) {
            let offset = Double(i - halfBars)
            let t = elapsed + (offset - frac) * secPerBar
            let x = CGFloat(i) * barW + barW / 2 - shift
            guard x > -barW && x < size.width + barW else { continue }

            drawBeatGridLine(ctx: ctx, x: x, size: size, time: t)

            let inTrack = hasTimeline && t >= -0.02 && t <= duration + 0.02
            let isPast = t < elapsed
            let fade: Double = inTrack ? (isPast ? 0.94 : 0.74) : 0.22
            let (bass, mid, hi) = bandsAt(time: t)
            drawRGBBar(ctx: ctx, x: x, barW: barW, midY: midY, maxH: maxH,
                       bass: bass, mid: mid, hi: hi, fade: fade)
        }

        drawPlayhead(ctx: ctx, x: midX, size: size)
        drawCueScrolling(ctx: ctx, size: size, elapsed: elapsed, secPerBar: secPerBar, shift: shift, barW: barW)
    }

    // MARK: - Overview (pista completa)

    private func drawOverview(ctx: GraphicsContext, size: CGSize) {
        let nBars = max(160, Int(size.width / 2))
        let barW = size.width / CGFloat(nBars)
        let midY = size.height / 2
        let maxH = size.height * 0.90
        let duration = durationSeconds
        let prog = hasTimeline ? min(max(progress ?? 0, 0), 1) : 0
        let playX = CGFloat(prog) * size.width

        if let loopIn = loopInFraction, let loopOut = loopOutFraction, loopIn < loopOut {
            let x1 = CGFloat(loopIn) * size.width
            let x2 = CGFloat(loopOut) * size.width
            ctx.fill(Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1), height: size.height)),
                     with: .color(Color.green.opacity(0.16)))
        }

        for i in 0..<nBars {
            let frac = (Double(i) + 0.5) / Double(nBars)
            let t = duration > 0 ? frac * duration : 0
            let x = CGFloat(i) * barW + barW / 2
            drawBeatGridLine(ctx: ctx, x: x, size: size, time: t)
            let isPast = hasTimeline && frac < prog
            let (bass, mid, hi) = bandsAt(time: t)
            drawRGBBar(ctx: ctx, x: x, barW: barW, midY: midY, maxH: maxH,
                       bass: bass, mid: mid, hi: hi, fade: isPast ? 0.95 : 0.68)
        }

        if hasTimeline {
            drawPlayhead(ctx: ctx, x: playX, size: size)
        }
        if let cue = cuePositionFraction {
            strokeMarker(ctx: ctx, x: CGFloat(cue) * size.width, size: size, color: Color.orange)
        }
    }

    // MARK: - Bandas RGB

    private func bandsAt(time t: Double) -> (Double, Double, Double) {
        if !peaks.isEmpty, durationSeconds > 0 {
            let amp = peakAt(time: t)
            return rgbFromPeak(amp, time: t)
        }
        let beat: Double
        if bpm > 20 {
            beat = t * bpm / 60.0
        } else {
            // Sin BPM real no inventamos 120: fase por tiempo, estable por seed.
            beat = t * 2.0
        }
        let bass = bandHeight(beat: beat, seed: trackSeed, freqA: 0.50, freqB: 1.03, phaseA: 0.017, phaseB: 0.031)
        let mid  = bandHeight(beat: beat, seed: trackSeed, freqA: 2.13, freqB: 3.07, phaseA: 0.011, phaseB: 0.019)
        let hi   = bandHeight(beat: beat, seed: trackSeed, freqA: 4.27, freqB: 6.11, phaseA: 0.007, phaseB: 0.009)
        if durationSeconds > 0 && (t < 0 || t > durationSeconds) {
            return (bass * 0.12, mid * 0.12, hi * 0.12)
        }
        return (bass, mid, hi)
    }

    private func peakAt(time t: Double) -> Float {
        let n = peaks.count
        guard n > 1, durationSeconds > 0 else { return peaks.first ?? 0 }
        if t < 0 || t > durationSeconds { return 0 }
        let x = (t / durationSeconds) * Double(n - 1)
        return interpPeak(x)
    }

    private func interpPeak(_ x: Double) -> Float {
        let n = peaks.count
        guard n > 0 else { return 0 }
        if x < 0 || x > Double(n - 1) { return 0 }
        let i = min(n - 1, max(0, Int(x)))
        let j = min(n - 1, i + 1)
        let t = Float(x - Double(i))
        return peaks[i] + (peaks[j] - peaks[i]) * t
    }

    private func rgbFromPeak(_ p: Float, time t: Double) -> (Double, Double, Double) {
        // CDJ-style spectral simulation: multi-rate oscillators create realistic
        // bass/mid/treble sections — red drops, cyan intros, green fills.
        let a = Double(max(0, min(1, p)))
        guard a > 0.005 else { return (0, 0, 0) }
        let s = Double(abs(trackSeed % 997) + 1)

        // Bass (red) evolves at phrase level — slow, high energy during drops.
        let bassOsc = sin(t * 0.13 + s * 0.013) * 0.42 +
                      sin(t * 0.37 + s * 0.029) * 0.23 +
                      sin(t * 0.89 + s * 0.007) * 0.11

        // Hi (cyan) evolves faster — hi-hats, fills, synth detail.
        let hiOsc   = sin(t * 0.47 + s * 0.019 + 2.10) * 0.38 +
                      sin(t * 1.31 + s * 0.011 + 3.70) * 0.22 +
                      sin(t * 3.17 + s * 0.037 + 1.20) * 0.10

        // Mid (green) — chords, pads, intermediate evolution.
        let midOsc  = sin(t * 0.23 + s * 0.023 + 4.71) * 0.35 +
                      sin(t * 0.61 + s * 0.031 + 1.90) * 0.20

        let bassChar = max(0.08, min(1.0, bassOsc + 0.72))
        let midChar  = max(0.03, min(1.0, midOsc  + 0.62))
        let hiChar   = max(0.03, min(1.0, hiOsc   + 0.58))

        return (
            min(1.0, a * bassChar),
            min(1.0, a * midChar * 0.82),
            min(1.0, a * hiChar  * 0.68)
        )
    }

    /// Graves en el eje, medios encima, agudos en el borde (espejo vertical).
    private func drawRGBBar(
        ctx: GraphicsContext,
        x: CGFloat, barW: CGFloat, midY: CGFloat, maxH: CGFloat,
        bass: Double, mid: Double, hi: Double, fade: Double
    ) {
        let bw = max(1, barW * 0.84)
        let bx = x - bw / 2
        let bassH = CGFloat(bass) * maxH * 0.48
        let midH  = CGFloat(mid)  * maxH * 0.30
        let hiH   = CGFloat(hi)   * maxH * 0.20

        func pair(_ yOff: CGFloat, _ h: CGFloat, _ color: Color) {
            guard h > 0.35 else { return }
            let top = CGRect(x: bx, y: midY - yOff - h, width: bw, height: h)
            let bot = CGRect(x: bx, y: midY + yOff, width: bw, height: h)
            ctx.fill(Path(top), with: .color(color.opacity(fade)))
            ctx.fill(Path(bot), with: .color(color.opacity(fade * 0.92)))
        }

        pair(0, bassH, Theme.wfBass)
        pair(bassH, midH, Theme.wfMid)
        pair(bassH + midH, hiH, Theme.wfHigh)
    }

    private func drawBeatGridLine(ctx: GraphicsContext, x: CGFloat, size: CGSize, time t: Double) {
        guard bpm > 20, t >= 0 else { return }
        let beat = t * bpm / 60.0
        let beatMod = beat.truncatingRemainder(dividingBy: 1.0)
        let wrapped = beatMod < 0 ? beatMod + 1 : beatMod
        let beatWidth = (windowSeconds / Double(totalBars)) * bpm / 60.0
        let slop = max(0.06, min(0.22, beatWidth * 0.45))
        guard wrapped < slop || wrapped > (1 - slop) else { return }
        let barMod = beat.truncatingRemainder(dividingBy: 4.0)
        let barWrapped = barMod < 0 ? barMod + 4 : barMod
        let isDownbeat = barWrapped < slop || barWrapped > (4 - slop)
        let isCurrent = beatInBar > 0 && Int(barWrapped) + 1 == beatInBar && isDownbeat
        ctx.fill(
            Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
            with: .color(Theme.wfBass.opacity(isCurrent ? 0.50 : (isDownbeat ? 0.34 : 0.10)))
        )
    }

    private func drawPlayhead(ctx: GraphicsContext, x: CGFloat, size: CGSize) {
        var ph = Path()
        ph.move(to: CGPoint(x: x, y: 0))
        ph.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(ph, with: .color(.white.opacity(isPlaying ? 0.98 : 0.78)), lineWidth: isPlaying ? 1.8 : 1.4)

        let top = Path { p in
            p.move(to: CGPoint(x: x - 5, y: 0))
            p.addLine(to: CGPoint(x: x + 5, y: 0))
            p.addLine(to: CGPoint(x: x, y: 7))
            p.closeSubpath()
        }
        ctx.fill(top, with: .color(.white))

        let bot = Path { p in
            p.move(to: CGPoint(x: x - 5, y: size.height))
            p.addLine(to: CGPoint(x: x + 5, y: size.height))
            p.addLine(to: CGPoint(x: x, y: size.height - 7))
            p.closeSubpath()
        }
        ctx.fill(bot, with: .color(.white))
    }

    private func drawLoopScrolling(ctx: GraphicsContext, size: CGSize, elapsed: Double, secPerBar: Double, shift: CGFloat, barW: CGFloat) {
        guard let loopIn = loopInFraction, let loopOut = loopOutFraction, loopIn < loopOut, durationSeconds > 0 else { return }
        let x1 = xForTime(loopIn * durationSeconds, elapsed: elapsed, secPerBar: secPerBar, shift: shift, barW: barW)
        let x2 = xForTime(loopOut * durationSeconds, elapsed: elapsed, secPerBar: secPerBar, shift: shift, barW: barW)
        if x2 > x1 {
            ctx.fill(Path(CGRect(x: x1, y: 0, width: x2 - x1, height: size.height)),
                     with: .color(Color.green.opacity(0.16)))
            ctx.fill(Path(CGRect(x: x1, y: 0, width: 1.5, height: size.height)),
                     with: .color(Color.green.opacity(0.80)))
            ctx.fill(Path(CGRect(x: x2 - 1.5, y: 0, width: 1.5, height: size.height)),
                     with: .color(Color.green.opacity(0.80)))
        }
    }

    private func drawCueScrolling(ctx: GraphicsContext, size: CGSize, elapsed: Double, secPerBar: Double, shift: CGFloat, barW: CGFloat) {
        guard let cueFrac = cuePositionFraction, durationSeconds > 0 else { return }
        let cx = xForTime(cueFrac * durationSeconds, elapsed: elapsed, secPerBar: secPerBar, shift: shift, barW: barW)
        guard cx >= 0 && cx <= size.width else { return }
        strokeMarker(ctx: ctx, x: cx, size: size, color: Color.orange)
    }

    private func strokeMarker(ctx: GraphicsContext, x: CGFloat, size: CGSize, color: Color) {
        var cp = Path()
        cp.move(to: CGPoint(x: x, y: 0))
        cp.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(cp, with: .color(color.opacity(0.90)), lineWidth: 2)
        let ct = Path { p in
            p.move(to: CGPoint(x: x - 5, y: 0))
            p.addLine(to: CGPoint(x: x + 5, y: 0))
            p.addLine(to: CGPoint(x: x, y: 7))
            p.closeSubpath()
        }
        ctx.fill(ct, with: .color(color))
    }

    private func xForTime(_ t: Double, elapsed: Double, secPerBar: Double, shift: CGFloat, barW: CGFloat) -> CGFloat {
        let offsetBars = (t - elapsed) / secPerBar
        return CGFloat(Double(halfBars) + offsetBars) * barW + barW / 2 - shift
    }

    private func bandHeight(beat: Double, seed: Int, freqA: Double, freqB: Double, phaseA: Double, phaseB: Double) -> Double {
        let s = Double(abs(seed % 997) + 1)
        let a = abs(sin(beat * freqA + s * phaseA)) * 0.55
        let b = abs(sin(beat * freqB + s * phaseB)) * 0.35
        let c = abs(sin(beat * (freqA + freqB) * 0.5 + s * (phaseA + phaseB))) * 0.10
        return min(1.0, max(0.06, a + b + c))
    }
}
