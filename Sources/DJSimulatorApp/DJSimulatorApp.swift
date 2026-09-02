// DJSimulatorApp.swift
// App independiente para probar SC6000 Connect sin el equipo.
// Permite cargar pistas de audio reales, muestra el waveform RGB con cues
// simulados y emite los datos por StageLinq y Pro DJ Link.

import SwiftUI
import AVFoundation
import Accelerate
import UniformTypeIdentifiers
import StageLinqKit

// MARK: - Punto de entrada

@main
struct DJSimulatorApp: App {
    @StateObject private var controller = SimulatorController()

    var body: some Scene {
        WindowGroup("Simulador de reproductores") {
            SimulatorView()
                .environmentObject(controller)
                .frame(minWidth: 680, minHeight: 520)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Pista cargada

struct LoadedTrack {
    let url:      URL
    let title:    String
    let artist:   String
    let duration: Double       // segundos
    let peaks:    [Float]      // ~500 valores de amplitud RMS para el waveform
    let cues:     [Double]     // posiciones en segundos de cues simulados
}

// MARK: - Controlador

final class SimulatorController: ObservableObject {
    @Published var denonRunning   = false
    @Published var pioneerRunning = false
    @Published var logLines:  [String] = []

    // Deck A y Deck B del simulador Denon
    @Published var trackA: LoadedTrack?
    @Published var trackB: LoadedTrack?
    @Published var playingA = false
    @Published var playingB = false
    @Published var posA: Double = 0   // segundos de reproducción
    @Published var posB: Double = 0

    private var denon:   DenonSimulator?
    private var pioneer: PioneerSimulator?

    private var timerA: Timer?
    private var timerB: Timer?

    // MARK: Log

    func log(_ message: String) {
        DispatchQueue.main.async {
            self.logLines.append(message)
            if self.logLines.count > 300 { self.logLines.removeFirst(self.logLines.count - 300) }
        }
    }

    // MARK: Denon / Pioneer

    func toggleDenon() {
        if denonRunning {
            denon?.stop(); denon = nil; denonRunning = false
        } else {
            let sim = DenonSimulator(log: { [weak self] in self?.log($0) })
            denon = sim; sim.start(); denonRunning = true
        }
    }

    func togglePioneer() {
        if pioneerRunning {
            pioneer?.stop(); pioneer = nil; pioneerRunning = false
        } else {
            let sim = PioneerSimulator(log: { [weak self] in self?.log($0) })
            pioneer = sim; sim.start(); pioneerRunning = true
        }
    }

    // MARK: Carga de pista

    func loadTrack(url: URL, deck: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let track = Self.analyzeAudio(url: url) else {
                self.log("❌ No se pudo leer el audio: \(url.lastPathComponent)")
                return
            }
            DispatchQueue.main.async {
                if deck == 1 { self.trackA = track; self.posA = 0; self.playingA = false }
                else          { self.trackB = track; self.posB = 0; self.playingB = false }
                self.log("🎵 Deck \(deck == 1 ? "A" : "B"): \(track.title) (\(Int(track.duration))s)")
            }
        }
    }

    // MARK: Playback simulado

    func togglePlay(deck: Int) {
        if deck == 1 {
            playingA.toggle()
            if playingA {
                timerA = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self, let track = self.trackA else { return }
                    self.posA = min(self.posA + 0.05, track.duration)
                    if self.posA >= track.duration { self.playingA = false; self.timerA?.invalidate() }
                }
            } else { timerA?.invalidate(); timerA = nil }
        } else {
            playingB.toggle()
            if playingB {
                timerB = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self, let track = self.trackB else { return }
                    self.posB = min(self.posB + 0.05, track.duration)
                    if self.posB >= track.duration { self.playingB = false; self.timerB?.invalidate() }
                }
            } else { timerB?.invalidate(); timerB = nil }
        }
    }

    func seek(deck: Int, to fraction: Double) {
        if deck == 1, let t = trackA { posA = fraction * t.duration }
        else if let t = trackB       { posB = fraction * t.duration }
    }

    // MARK: Análisis de audio

    static func analyzeAudio(url: URL) -> LoadedTrack? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format   = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0] else { return nil }

        let count    = Int(buffer.frameLength)
        let duration = Double(count) / format.sampleRate

        // RMS en 500 bloques para el waveform
        let numBuckets = 500
        let blockSize  = max(1, count / numBuckets)
        var peaks = [Float](repeating: 0, count: numBuckets)
        for i in 0..<numBuckets {
            let start = i * blockSize
            let end   = min(start + blockSize, count)
            var rms: Float = 0
            vDSP_rmsqv(samples + start, 1, &rms, vDSP_Length(end - start))
            peaks[i] = rms
        }
        // Normalizar
        var maxV: Float = 0
        vDSP_maxv(peaks, 1, &maxV, vDSP_Length(numBuckets))
        if maxV > 0 { vDSP_vsdiv(peaks, 1, &maxV, &peaks, 1, vDSP_Length(numBuckets)) }

        // Cues simulados: 4 puntos repartidos en la pista
        let cues: [Double] = [duration * 0.05, duration * 0.25, duration * 0.50, duration * 0.75]

        // Metadatos del nombre de archivo
        let stem   = url.deletingPathExtension().lastPathComponent
        let parts  = stem.components(separatedBy: " - ")
        let artist = parts.count > 1 ? parts[0] : ""
        let title  = parts.count > 1 ? parts[1...].joined(separator: " - ") : stem

        return LoadedTrack(url: url, title: title, artist: artist, duration: duration, peaks: peaks, cues: cues)
    }
}

// MARK: - Vista principal

struct SimulatorView: View {
    @EnvironmentObject var controller: SimulatorController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                DeckSimPanel(deck: 1)
                Divider()
                DeckSimPanel(deck: 2)
            }
            .frame(maxHeight: 300)
            Divider()
            networkRow
            Divider()
            logPanel
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SIMULADOR DE REPRODUCTORES")
                    .font(.system(size: 13, weight: .bold)).tracking(1.0)
                Text("Carga pistas reales y prueba SC6000 Connect sin el equipo.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var networkRow: some View {
        HStack(spacing: 12) {
            SimulatorButton(title: "Denon SC6000", subtitle: "StageLinq",
                            running: controller.denonRunning, color: .orange) { controller.toggleDenon() }
            SimulatorButton(title: "Pioneer CDJ-3000", subtitle: "Pro DJ Link",
                            running: controller.pioneerRunning, color: .cyan) { controller.togglePioneer() }
        }
        .padding(14)
    }

    private var logPanel: some View {
        Group {
            Text("REGISTRO")
                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundColor(.secondary).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Panel de un deck

struct DeckSimPanel: View {
    let deck: Int
    @EnvironmentObject var controller: SimulatorController

    private var track: LoadedTrack? { deck == 1 ? controller.trackA : controller.trackB }
    private var pos:   Double       { deck == 1 ? controller.posA   : controller.posB }
    private var playing: Bool       { deck == 1 ? controller.playingA : controller.playingB }
    private var label: String       { deck == 1 ? "DECK A" : "DECK B" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Cabecera del deck
            HStack {
                Circle().fill(playing ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11, weight: .bold)).tracking(0.8)
                Spacer()
                if let t = track {
                    Text(formatTime(pos) + " / " + formatTime(t.duration))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
            }

            if let t = track {
                // Waveform real
                RealWaveformView(peaks: t.peaks, progress: t.duration > 0 ? pos / t.duration : 0,
                                 cues: t.cues.map { $0 / t.duration }, isPlaying: playing)
                    .frame(height: 60)

                // Barra de progreso clickeable
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.10))
                        RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.70))
                            .frame(width: max(2, geo.size.width * CGFloat(t.duration > 0 ? pos / t.duration : 0)))
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { val in
                        let frac = max(0, min(1, Double(val.location.x / geo.size.width)))
                        controller.seek(deck: deck, to: frac)
                    })
                }
                .frame(height: 8)

                // Cues rápidos
                HStack(spacing: 6) {
                    ForEach(Array(t.cues.enumerated()), id: \.offset) { i, cue in
                        Button("CUE \(i + 1)") { controller.seek(deck: deck, to: cue / t.duration) }
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.15)))
                            .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // Título y artista
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title.isEmpty ? t.url.lastPathComponent : t.title)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if !t.artist.isEmpty {
                        Text(t.artist).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            } else {
                // Placeholder sin pista
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05))
                    .frame(height: 60)
                    .overlay(Text("Sin pista").font(.system(size: 11)).foregroundColor(.secondary))
            }

            // Botones Play/Stop y Cargar
            HStack(spacing: 8) {
                Button(action: { controller.togglePlay(deck: deck) }) {
                    Label(playing ? "DETENER" : "PLAY",
                          systemImage: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(playing ? .red : .green)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill((playing ? Color.red : Color.green).opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                // File picker
                FilePicker(deck: deck)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatTime(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Waveform con peaks reales

struct RealWaveformView: View {
    let peaks:     [Float]    // 0…1 valores de amplitud
    let progress:  Double     // 0…1
    let cues:      [Double]   // 0…1 fracciones de los cues
    let isPlaying: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = peaks.count
            guard n > 0 else { return }

            let barW = size.width / CGFloat(n)
            let midY = size.height / 2.0
            let playX = size.width * CGFloat(progress)

            // Barras de amplitud coloreadas según posición relativa al playhead
            for i in 0..<n {
                let amp   = CGFloat(peaks[i])
                let barH  = max(2, amp * size.height * 0.88)
                let x     = CGFloat(i) * barW
                let isPast = x < playX

                // Color RGB: graves siempre rojos, agudos cian basado en amp
                let r: Double = isPast ? 0.85 : 0.50
                let g: Double = isPast ? Double(amp) * 0.60 : Double(amp) * 0.35
                let b: Double = isPast ? Double(amp) * 0.90 : Double(amp) * 0.55
                let alpha: Double = isPast ? 0.90 : 0.55

                let rect = CGRect(x: x, y: midY - barH / 2, width: max(1, barW - 0.5), height: barH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                         with: .color(Color(red: r, green: g, blue: b).opacity(alpha)))
            }

            // Línea del playhead
            var ph = Path()
            ph.move(to:    CGPoint(x: playX, y: 0))
            ph.addLine(to: CGPoint(x: playX, y: size.height))
            ctx.stroke(ph, with: .color(.white.opacity(0.90)), lineWidth: 1.5)

            // Marcadores de cue (naranja)
            for cueFrac in cues {
                let cx = size.width * CGFloat(cueFrac)
                var cp = Path()
                cp.move(to:    CGPoint(x: cx, y: 0))
                cp.addLine(to: CGPoint(x: cx, y: size.height))
                ctx.stroke(cp, with: .color(Color.orange.opacity(0.80)), lineWidth: 1.5)
            }
        }
        .background(Color.black.opacity(0.50))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - File picker

struct FilePicker: View {
    let deck: Int
    @EnvironmentObject var controller: SimulatorController

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType.audio]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                controller.loadTrack(url: url, deck: deck)
            }
        } label: {
            Label("Cargar pista…", systemImage: "folder.badge.plus")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Botón de simulador de red

private struct SimulatorButton: View {
    let title: String; let subtitle: String
    let running: Bool; let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(running ? color : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                Text(running ? "DETENER" : "ARRANCAR")
                    .font(.system(size: 10, weight: .bold)).foregroundColor(running ? .red : color)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(running ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(running ? color.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
