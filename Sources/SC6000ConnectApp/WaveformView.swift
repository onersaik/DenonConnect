// WaveformView.swift
// RGB tipo CDJ / Serato: barras finas simétricas. Color = energía real
// low/mid/high del audio (no heatmap ni senos). Sin picos: envolvente plana.

import SwiftUI

enum WaveformMode {
    /// Ventana que se desplaza; playhead fijo al centro (vista Grande / MASTER).
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
    var peaks:       [UInt8] = []
    var peaksLow:    [UInt8] = []
    var peaksMid:    [UInt8] = []
    var peaksHigh:   [UInt8] = []
    /// Segundos reales del playhead (jog / SMPTE). Si falta, se usa progress × duración.
    var elapsed: Double? = nil
    var cuePositionFraction: Double? = nil
    var extraCueFractions: [Double] = []
    var loopInFraction:  Double? = nil
    var loopOutFraction: Double? = nil
    var mode: WaveformMode = .scrolling
    /// Ventana visible en segundos. CDJ ~12 s. Más corta = más detalle; más larga = más contexto.
    var windowSeconds: Double = 12.0
    /// Velocidad real del deck (1.0 = neutro). Estira/comprime la ventana y la rejilla.
    var playbackRate: Double = 1.0
    var canvasBackground: Color = Color.black
    var playheadColor: Color = Color.white

    /// Todas las marcas de cue (memoria + pads TEST), 0…1.
    private var allCueFractions: [Double] {
        var out = extraCueFractions.filter { $0 >= 0 && $0 <= 1 }
        if let c = cuePositionFraction, c >= 0, c <= 1 {
            if !out.contains(where: { abs($0 - c) < 0.0008 }) {
                out.append(c)
            }
        }
        return out
    }

    var body: some View {
        Group {
            if isPlaying, durationSeconds > 0 {
                // Redibuja el Canvas a 30 fps aunque el padre no tenga TimelineView.
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                    waveformCanvas
                }
            } else {
                waveformCanvas
            }
        }
        .transaction { $0.animation = nil }
        .frame(minHeight: 36)
        .background(canvasBackground)
    }

    private var waveformCanvas: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(canvasBackground))
            let midY = size.height / 2
            ctx.fill(
                Path(CGRect(x: 0, y: midY - 0.4, width: size.width, height: 0.8)),
                with: .color(playheadColor.opacity(0.10))
            )
            if mode == .overview {
                drawOverview(ctx: ctx, size: size)
            } else {
                drawScrolling(ctx: ctx, size: size)
            }
        }
    }

    // MARK: - Tiempo real de la pista

    private var elapsedSeconds: Double {
        if let e = elapsed, e.isFinite, e >= 0 {
            return durationSeconds > 0 ? min(e, durationSeconds) : e
        }
        if let p = progress, let l = trackLength, l > 0, p.isFinite, l.isFinite {
            return min(max(p, 0), 1) * l
        }
        return 0
    }

    private var durationSeconds: Double {
        let l = trackLength ?? 0
        return l > 0 && l.isFinite ? l : 0
    }

    private var progressFraction: Double {
        if let p = progress, p.isFinite { return min(max(p, 0), 1) }
        if durationSeconds > 0, let e = elapsed, e.isFinite, e >= 0 {
            return min(max(e / durationSeconds, 0), 1)
        }
        return 0
    }

    private var hasTimeline: Bool {
        guard durationSeconds > 0 else { return false }
        if let p = progress, p.isFinite { return true }
        if let e = elapsed, e.isFinite, e >= 0 { return true }
        // BeatInfo vivo sin elapsed explícito: isPlaying + bpm basta para interpolar.
        if isPlaying, bpm > 20 { return true }
        return false
    }

    private var hasRGB: Bool {
        let n = peaksLow.count
        return n > 1 && peaksMid.count == n && peaksHigh.count == n
    }

    // MARK: - Scrolling: playhead al centro, scroll subpíxel

    private func drawScrolling(ctx: GraphicsContext, size: CGSize) {
        // CDJ-3000: barras finas, ~2.5 por pixel. Misma ventana, más barras/s.
        let cols = max(480, Int(size.width / 0.40))
        let colW = size.width / CGFloat(cols)
        let midX = size.width / 2
        let elapsed = elapsedSeconds
        let duration = durationSeconds
        // Pitch: rate < 1 estira (más zoom), rate > 1 comprime. Mantiene
        // la sensación de cinta / cabezal vari-speed en la onda.
        let rate = (playbackRate.isFinite && playbackRate > 0.05) ? min(4.0, max(0.25, playbackRate)) : 1.0
        let effectiveWindow = windowSeconds * rate
        let secPerCol = effectiveWindow / Double(cols)
        let exact = elapsed / secPerCol
        let frac = exact - floor(exact)
        let shift = CGFloat(frac) * colW

        drawLoopScrolling(ctx: ctx, size: size, elapsed: elapsed, secPerCol: secPerCol, shift: shift, colW: colW, cols: cols)

        for i in 0...cols {
            let offset = Double(i) - Double(cols) / 2
            let t = elapsed + (offset - frac) * secPerCol
            let x = CGFloat(i) * colW - shift
            guard x > -colW && x < size.width + colW else { continue }

            drawBeatGridLine(ctx: ctx, x: x, size: size, time: t, secPerCol: secPerCol)

            let inTrack = hasTimeline && t >= -0.02 && t <= duration + 0.02
            let isPast = t < elapsed
            let fade: Double = inTrack ? (isPast ? 1.0 : 0.78) : 0.16
            drawColumn(ctx: ctx, x: x, colW: colW, size: size, time: t, fade: fade, sliceSeconds: secPerCol)
        }

        drawPlayhead(ctx: ctx, x: midX, size: size)
        drawCueScrolling(ctx: ctx, size: size, elapsed: elapsed, secPerCol: secPerCol, shift: shift, colW: colW, cols: cols)
    }

    // MARK: - Overview (pista completa)

    private func drawOverview(ctx: GraphicsContext, size: CGSize) {
        let cols = max(400, Int(size.width / 0.50))
        let colW = size.width / CGFloat(cols)
        let duration = durationSeconds
        let prog = hasTimeline ? progressFraction : 0
        let playX = CGFloat(prog) * size.width
        let slice = duration > 0 ? duration / Double(cols) : 0.02

        if let loopIn = loopInFraction, let loopOut = loopOutFraction, loopIn < loopOut {
            let x1 = CGFloat(loopIn) * size.width
            let x2 = CGFloat(loopOut) * size.width
            ctx.fill(Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1), height: size.height)),
                     with: .color(Color.green.opacity(0.16)))
            ctx.fill(Path(CGRect(x: x1, y: 0, width: 1.5, height: size.height)),
                     with: .color(Color.green.opacity(0.80)))
            ctx.fill(Path(CGRect(x: x2 - 1.5, y: 0, width: 1.5, height: size.height)),
                     with: .color(Color.green.opacity(0.80)))
        }

        for i in 0..<cols {
            let frac = (Double(i) + 0.5) / Double(cols)
            let t = duration > 0 ? frac * duration : 0
            let x = CGFloat(i) * colW
            let isPast = hasTimeline && frac < prog
            drawColumn(ctx: ctx, x: x, colW: colW, size: size, time: t, fade: isPast ? 1.0 : 0.72, sliceSeconds: slice)
        }

        if hasTimeline {
            drawPlayhead(ctx: ctx, x: playX, size: size)
        }
        for cue in allCueFractions {
            strokeMarker(ctx: ctx, x: CGFloat(cue) * size.width, size: size, color: Color.orange)
        }
    }

    // MARK: - Columna RGB (CDJ / Serato)

    private func drawColumn(ctx: GraphicsContext, x: CGFloat, colW: CGFloat, size: CGSize, time t: Double, fade: Double, sliceSeconds: Double) {
        let bands = sampleBands(time: t, sliceSeconds: sliceSeconds)
        guard bands.amp > 0.012, fade > 0.05 else { return }

        let midY = size.height / 2
        let maxH = size.height * 0.48
        let gap = max(0.04, colW * 0.04)
        let bw = max(0.32, colW - gap)
        let bx = x + gap * 0.5

        if hasRGB {
            drawRGBBar(ctx: ctx, bx: bx, bw: bw, midY: midY, maxH: maxH, bands: bands, fade: fade)
        } else {
            let h = max(1.0, CGFloat(bands.amp) * maxH)
            var g = ctx
            g.opacity = fade
            let color = Color(red: 0.22, green: 0.82, blue: 1.00)
            g.fill(Path(CGRect(x: bx, y: midY - h, width: bw, height: h)), with: .color(color))
            g.opacity = fade * 0.88
            g.fill(Path(CGRect(x: bx, y: midY, width: bw, height: h)), with: .color(color))
        }
    }

    /// Tres capas desde el eje, sin huecos: low rojo, mid verde, high azul.
    /// Donde se superponen se mezclan (núcleo más claro, puntas del color dominante).
    private func drawRGBBar(ctx: GraphicsContext, bx: CGFloat, bw: CGFloat, midY: CGFloat, maxH: CGFloat, bands: Bands, fade: Double) {
        struct Layer {
            var h: CGFloat
            var r: Double
            var g: Double
            var b: Double
        }
        var layers = [
            Layer(h: CGFloat(bands.low) * maxH,  r: 1.00, g: 0.30, b: 0.05),
            Layer(h: CGFloat(bands.mid) * maxH,  r: 0.20, g: 0.95, b: 0.12),
            Layer(h: CGFloat(bands.high) * maxH, r: 0.10, g: 0.55, b: 1.00),
        ]
        layers.sort { $0.h < $1.h }

        var prev: CGFloat = 0
        for i in 0..<layers.count {
            let h = layers[i].h
            let dh = h - prev
            if dh < 0.35 {
                prev = max(prev, h)
                continue
            }
            var r = 0.0, g = 0.0, b = 0.0
            for j in i..<layers.count {
                r += layers[j].r
                g += layers[j].g
                b += layers[j].b
            }
            let color = Color(red: min(1, r), green: min(1, g), blue: min(1, b))
            var gc = ctx
            gc.opacity = fade
            gc.fill(Path(CGRect(x: bx, y: midY - h, width: bw, height: dh)), with: .color(color))
            gc.opacity = fade * 0.90
            gc.fill(Path(CGRect(x: bx, y: midY + prev, width: bw, height: dh)), with: .color(color))
            prev = h
        }
    }

    private struct Bands {
        var low: Double
        var mid: Double
        var high: Double
        var amp: Double { max(low, mid, high) }
    }

    private func sampleBands(time t: Double, sliceSeconds: Double) -> Bands {
        let outside = durationSeconds > 0 && (t < 0 || t > durationSeconds)
        let scale = outside ? 0.08 : 1.0

        if hasRGB {
            let low = Double(maxInSlice(peaksLow, time: t, slice: sliceSeconds))
            let mid = Double(maxInSlice(peaksMid, time: t, slice: sliceSeconds))
            let high = Double(maxInSlice(peaksHigh, time: t, slice: sliceSeconds))
            return Bands(low: low * scale, mid: mid * scale, high: high * scale)
        }
        if !peaks.isEmpty, durationSeconds > 0 {
            let a = Double(maxInSlice(peaks, time: t, slice: sliceSeconds)) * scale
            return Bands(low: a, mid: a, high: a)
        }
        // Sin picos reales: envolvente procedural con variación por seed+tiempo.
        let inTrack = durationSeconds > 0 && t >= 0 && t <= durationSeconds
        if inTrack {
            // Hash rápido: seed + columna temporal → variación 0.25–0.75
            let col = durationSeconds > 0 ? Int(t / durationSeconds * 800) : 0
            var h = UInt64(bitPattern: Int64(trackSeed &* 31 &+ col))
            h = (h ^ (h >> 30)) &* 0xbf58476d1ce4e5b9
            h = (h ^ (h >> 27)) &* 0x94d049bb133111eb
            h = h ^ (h >> 31)
            let r = Double(h % 512) / 1024.0 // 0–0.5
            return Bands(low: (0.35 + r * 0.45) * scale,
                         mid: (0.25 + r * 0.35) * scale,
                         high: (0.15 + r * 0.25) * scale)
        }
        return Bands(low: 0, mid: 0, high: 0)
    }

    /// Si la columna cubre varios bins: máximo real. Si es sub-bin: lerp.
    private func maxInSlice(_ arr: [UInt8], time t: Double, slice: Double) -> Float {
        let n = arr.count
        guard n > 0 else { return 0 }
        guard durationSeconds > 0 else { return Float(arr[0]) / 255.0 }
        if t + slice * 0.5 < 0 || t - slice * 0.5 > durationSeconds { return 0 }
        let span = max(slice, 0.0001)
        let t0 = max(0, t - span * 0.5)
        let t1 = min(durationSeconds, t + span * 0.5)
        let f0 = (t0 / durationSeconds) * Double(n - 1)
        let f1 = (t1 / durationSeconds) * Double(n - 1)
        if f1 - f0 < 1.0 {
            return lerpPeak(arr, at: (t / durationSeconds) * Double(n - 1))
        }
        var i0 = Int(f0)
        var i1 = Int(f1)
        if i0 < 0 { i0 = 0 }
        if i1 >= n { i1 = n - 1 }
        if i1 < i0 { i1 = i0 }
        var mx: UInt8 = 0
        var i = i0
        while i <= i1 {
            if arr[i] > mx { mx = arr[i] }
            i += 1
        }
        return Float(mx) / 255.0
    }

    private func lerpPeak(_ arr: [UInt8], at index: Double) -> Float {
        let n = arr.count
        guard n > 1 else { return Float(arr.first ?? 0) / 255.0 }
        let clamped = min(Double(n - 1), max(0, index))
        let i0 = Int(clamped)
        let i1 = min(n - 1, i0 + 1)
        let frac = Float(clamped - Double(i0))
        let a = Float(arr[i0]) / 255.0
        let b = Float(arr[i1]) / 255.0
        return a + (b - a) * frac
    }

    private func drawBeatGridLine(ctx: GraphicsContext, x: CGFloat, size: CGSize, time t: Double, secPerCol: Double) {
        guard bpm > 20, t >= 0 else { return }
        let beat = t * bpm / 60.0
        let beatMod = beat.truncatingRemainder(dividingBy: 1.0)
        let wrapped = beatMod < 0 ? beatMod + 1 : beatMod
        let beatWidth = secPerCol * bpm / 60.0
        let slop = max(0.06, min(0.22, beatWidth * 0.45))
        guard wrapped < slop || wrapped > (1 - slop) else { return }
        let barMod = beat.truncatingRemainder(dividingBy: 4.0)
        let barWrapped = barMod < 0 ? barMod + 4 : barMod
        let isDownbeat = barWrapped < slop || barWrapped > (4 - slop)
        guard isDownbeat else { return }
        let isCurrent = beatInBar > 0 && Int(barWrapped) + 1 == beatInBar
        ctx.fill(
            Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
            with: .color(playheadColor.opacity(isCurrent ? 0.55 : 0.22))
        )
    }

    private func drawPlayhead(ctx: GraphicsContext, x: CGFloat, size: CGSize) {
        var glow = Path()
        glow.move(to: CGPoint(x: x, y: 0))
        glow.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(glow, with: .color(playheadColor.opacity(0.22)), lineWidth: 5)

        var ph = Path()
        ph.move(to: CGPoint(x: x, y: 0))
        ph.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(ph, with: .color(playheadColor.opacity(isPlaying ? 0.98 : 0.78)), lineWidth: isPlaying ? 1.6 : 1.2)

        let top = Path { p in
            p.move(to: CGPoint(x: x - 5, y: 0))
            p.addLine(to: CGPoint(x: x + 5, y: 0))
            p.addLine(to: CGPoint(x: x, y: 7))
            p.closeSubpath()
        }
        ctx.fill(top, with: .color(playheadColor))

        let bot = Path { p in
            p.move(to: CGPoint(x: x - 5, y: size.height))
            p.addLine(to: CGPoint(x: x + 5, y: size.height))
            p.addLine(to: CGPoint(x: x, y: size.height - 7))
            p.closeSubpath()
        }
        ctx.fill(bot, with: .color(playheadColor))
    }

    private func drawLoopScrolling(ctx: GraphicsContext, size: CGSize, elapsed: Double, secPerCol: Double, shift: CGFloat, colW: CGFloat, cols: Int) {
        guard let loopIn = loopInFraction, let loopOut = loopOutFraction, loopIn < loopOut, durationSeconds > 0 else { return }
        let x1 = xForTime(loopIn * durationSeconds, elapsed: elapsed, secPerCol: secPerCol, shift: shift, colW: colW, cols: cols)
        let x2 = xForTime(loopOut * durationSeconds, elapsed: elapsed, secPerCol: secPerCol, shift: shift, colW: colW, cols: cols)
        if x2 > x1 {
            ctx.fill(Path(CGRect(x: x1, y: 0, width: x2 - x1, height: size.height)),
                     with: .color(Color.green.opacity(0.16)))
            ctx.fill(Path(CGRect(x: x1, y: 0, width: 1.5, height: size.height)),
                     with: .color(Color.green.opacity(0.80)))
            ctx.fill(Path(CGRect(x: x2 - 1.5, y: 0, width: 1.5, height: size.height)),
                     with: .color(Color.green.opacity(0.80)))
        }
    }

    private func drawCueScrolling(ctx: GraphicsContext, size: CGSize, elapsed: Double, secPerCol: Double, shift: CGFloat, colW: CGFloat, cols: Int) {
        guard durationSeconds > 0 else { return }
        for cueFrac in allCueFractions {
            let cx = xForTime(cueFrac * durationSeconds, elapsed: elapsed, secPerCol: secPerCol, shift: shift, colW: colW, cols: cols)
            guard cx >= 0 && cx <= size.width else { continue }
            strokeMarker(ctx: ctx, x: cx, size: size, color: Color.orange)
        }
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

    private func xForTime(_ t: Double, elapsed: Double, secPerCol: Double, shift: CGFloat, colW: CGFloat, cols: Int) -> CGFloat {
        let offsetCols = (t - elapsed) / secPerCol
        return (CGFloat(cols) / 2 + CGFloat(offsetCols)) * colW - shift
    }

}
