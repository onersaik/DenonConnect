// DJSimulatorApp.swift
// STAGE CONNECT TEST — simula reproductores reales en la red para validar
// la app principal sin necesidad de hardware.

import SwiftUI
import AppKit
import AVFoundation
import Accelerate
import UniformTypeIdentifiers
import StageLinqKit

// MARK: - App

@main
struct DJSimulatorApp: App {
    @StateObject private var controller = SimulatorController()

    var body: some Scene {
        WindowGroup("STAGE CONNECT TEST") {
            SimulatorView()
                .environmentObject(controller)
                .frame(minWidth: 820, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - LoadedTrack

struct LoadedTrack {
    var url: URL
    var title: String
    var artist: String
    var duration: Double
    var peaks: [Float]          // 600 buckets RMS
    var cues: [Double]
    var bpm: Double
    var key: String
}

// Cache leíble desde el hilo del simulador (clock / StateMap) sin tocar @MainActor.
final class DeckStateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [SimDeckState] = [SimDeckState(), SimDeckState()]

    func read() -> [SimDeckState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    func write(_ newStates: [SimDeckState]) {
        lock.lock()
        defer { lock.unlock() }
        states = newStates
    }
}

// MARK: - Reproductor (AVAudioEngine)

/// AVAudioPlayer falla con Opus/Ogg de WhatsApp. Decodificamos a PCM con
/// AVAudioFile (el mismo decoder del waveform) y reproducimos el buffer.
final class DeckAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var pcmBuffer: AVAudioPCMBuffer?
    private var startFrame: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var lengthFrames: AVAudioFramePosition = 0

    var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(lengthFrames) / sampleRate
    }

    var currentTime: Double {
        let base = sampleRate > 0 ? Double(startFrame) / sampleRate : 0
        guard node.isPlaying,
              let nodeTime = node.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return base
        }
        return base + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    var isPlaying: Bool { node.isPlaying && engine.isRunning }

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
    }

    func load(url: URL) throws {
        node.stop()
        let f = try AVAudioFile(forReading: url)
        let format = f.processingFormat
        sampleRate = format.sampleRate
        lengthFrames = f.length
        startFrame = 0
        guard f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw NSError(domain: "STAGE CONNECT TEST", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No se pudo reservar el buffer PCM"])
        }
        try f.read(into: buf)
        pcmBuffer = buf
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func play(from seconds: Double) throws {
        guard let src = pcmBuffer else {
            throw NSError(domain: "STAGE CONNECT TEST", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No hay archivo de audio cargado"])
        }
        if !engine.isRunning {
            try engine.start()
        }
        let sr = max(1, sampleRate)
        let maxFrame = max(AVAudioFramePosition(0), AVAudioFramePosition(src.frameLength))
        let frame = AVAudioFramePosition(max(0, min(Double(maxFrame), seconds * sr)))
        startFrame = frame
        guard let slice = Self.slice(src, from: frame) else {
            throw NSError(domain: "STAGE CONNECT TEST", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Seek fuera de rango"])
        }
        node.stop()
        node.scheduleBuffer(slice, at: nil, options: [])
        node.play()
        if !node.isPlaying {
            throw NSError(domain: "STAGE CONNECT TEST", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayerNode no arrancó"])
        }
    }

    func pauseKeepingPosition() {
        let t = currentTime
        node.stop()
        startFrame = AVAudioFramePosition(max(0, t * sampleRate))
    }

    func stopAndReset() {
        node.stop()
        startFrame = 0
    }

    func seek(seconds: Double) {
        let was = isPlaying
        let t = max(0, min(duration, seconds))
        startFrame = AVAudioFramePosition(t * sampleRate)
        if was {
            try? play(from: t)
        }
    }

    private static func slice(_ src: AVAudioPCMBuffer, from start: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let total = AVAudioFramePosition(src.frameLength)
        guard start < total else { return nil }
        let remaining = AVAudioFrameCount(total - start)
        guard remaining > 0,
              let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: remaining) else { return nil }
        out.frameLength = remaining
        let channels = Int(src.format.channelCount)
        if let inF = src.floatChannelData, let outF = out.floatChannelData {
            for c in 0..<channels {
                outF[c].update(from: inF[c].advanced(by: Int(start)), count: Int(remaining))
            }
            return out
        }
        if let inI = src.int16ChannelData, let outI = out.int16ChannelData {
            for c in 0..<channels {
                outI[c].update(from: inI[c].advanced(by: Int(start)), count: Int(remaining))
            }
            return out
        }
        if let inI = src.int32ChannelData, let outI = out.int32ChannelData {
            for c in 0..<channels {
                outI[c].update(from: inI[c].advanced(by: Int(start)), count: Int(remaining))
            }
            return out
        }
        return nil
    }
}

// MARK: - SimulatorController

@MainActor
final class SimulatorController: ObservableObject {

    // Deck state (main thread)
    @Published var trackA: LoadedTrack?
    @Published var trackB: LoadedTrack?
    @Published var posA: Double = 0    // 0-1
    @Published var posB: Double = 0
    @Published var playingA = false
    @Published var playingB = false
    @Published var bpmA: Double = 0
    @Published var bpmB: Double = 0

    // Network
    @Published var denonRunning = false
    @Published var pioneerRunning = false
    @Published var logLines: [String] = []

    private let audioA = DeckAudioPlayer()
    private let audioB = DeckAudioPlayer()
    private var denon: DenonSimulator?
    private var pioneer: PioneerSimulator?
    private var posTimer: Timer?

    private let stateCache = DeckStateCache()
    private let testLink = TestLinkPublisher()

    init() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.syncPositions() }
        }
        RunLoop.main.add(t, forMode: .common)
        posTimer = t
    }

    /// BPM que sale por TestLink y por el simulador de red. Nunca 0 si hay pista
    /// y ya se analizó o el usuario lo tocó.
    private func publishedBPM(deck: Int) -> Double {
        if deck == 1 {
            return MusicalClock.bpm(bpmA, trackA?.bpm ?? 0)
        }
        return MusicalClock.bpm(bpmB, trackB?.bpm ?? 0)
    }

    /// Fuente de verdad para Denon/Pioneer: escribir en cada play/pausa/seek/carga.
    private func pushState() {
        stateCache.write(buildStates())
        testLink.send(TestLinkSnapshot(
            denonOn: denonRunning,
            pioneerOn: pioneerRunning,
            decks: [
                TestLinkDeck(
                    title: trackA?.title ?? "",
                    artist: trackA?.artist ?? "",
                    bpm: trackA == nil ? 0 : publishedBPM(deck: 1),
                    playing: playingA,
                    position: posA * (trackA?.duration ?? 0),
                    duration: trackA?.duration ?? 0,
                    peaks: TestLinkDeck.quantize(trackA?.peaks ?? []),
                    isMaster: playingA || !playingB,
                    key: trackA?.key ?? ""
                ),
                TestLinkDeck(
                    title: trackB?.title ?? "",
                    artist: trackB?.artist ?? "",
                    bpm: trackB == nil ? 0 : publishedBPM(deck: 2),
                    playing: playingB,
                    position: posB * (trackB?.duration ?? 0),
                    duration: trackB?.duration ?? 0,
                    peaks: TestLinkDeck.quantize(trackB?.peaks ?? []),
                    isMaster: playingB && !playingA,
                    key: trackB?.key ?? ""
                )
            ]
        ))
    }

    private func syncPositions() {
        if let t = trackA {
            let cur = audioA.currentTime
            posA = t.duration > 0 ? min(1, max(0, cur / t.duration)) : 0
            if playingA, !audioA.isPlaying, posA >= 0.999 {
                playingA = false
            }
        }
        if let t = trackB {
            let cur = audioB.currentTime
            posB = t.duration > 0 ? min(1, max(0, cur / t.duration)) : 0
            if playingB, !audioB.isPlaying, posB >= 0.999 {
                playingB = false
            }
        }
        pushState()
    }

    private func buildStates() -> [SimDeckState] {
        [
            SimDeckState(
                title: trackA?.title ?? "",
                artist: trackA?.artist ?? "",
                bpm: trackA == nil ? 0 : publishedBPM(deck: 1),
                isPlaying: playingA,
                positionSeconds: posA * (trackA?.duration ?? 0),
                duration: trackA?.duration ?? 0,
                isMaster: playingA || !playingB,
                key: ""),
            SimDeckState(
                title: trackB?.title ?? "",
                artist: trackB?.artist ?? "",
                bpm: trackB == nil ? 0 : publishedBPM(deck: 2),
                isPlaying: playingB,
                positionSeconds: posB * (trackB?.duration ?? 0),
                duration: trackB?.duration ?? 0,
                isMaster: playingB && !playingA,
                key: "")
        ]
    }

    // MARK: - Track loading

    func loadTrack(url: URL, deck: Int) {
        let accessed = url.startAccessingSecurityScopedResource()
        log("[Carga] \(url.lastPathComponent) -> Deck \(deck == 1 ? "A" : "B")...")
        Task.detached(priority: .userInitiated) {
            let imported = Self.copyToTemp(url) ?? url
            let names = TrackNaming.parse(fileURL: url)
            let analyzed = await Self.analyzeAudio(url: imported)
            await MainActor.run {
                if accessed { url.stopAccessingSecurityScopedResource() }
                guard var track = analyzed else {
                    self.log("[Error] No se pudo leer el archivo (\(url.lastPathComponent)). Formato no soportado.")
                    return
                }
                track.title = names.title
                track.artist = names.artist
                // Orden: nombre de archivo → tag ID3/iTunes → estimación del audio.
                let namedBPM = Self.detectBPM(fromFileName: url)
                let tagged = Self.taggedMetadata(url: imported)
                track.bpm = MusicalClock.bpm(namedBPM, tagged.bpm, track.bpm)
                if !tagged.key.isEmpty { track.key = tagged.key }
                do {
                    if deck == 1 {
                        self.audioA.stopAndReset()
                        try self.audioA.load(url: imported)
                        self.trackA = track
                        self.posA = 0
                        self.playingA = false
                        self.bpmA = track.bpm
                        self.log("[Deck A] \(track.title) — \(String(format:"%.1f",track.duration))s \(track.bpm > 0 ? String(format:"%.1f BPM", track.bpm) : "sin BPM detectado")")
                    } else {
                        self.audioB.stopAndReset()
                        try self.audioB.load(url: imported)
                        self.trackB = track
                        self.posB = 0
                        self.playingB = false
                        self.bpmB = track.bpm
                        self.log("[Deck B] \(track.title) — \(String(format:"%.1f",track.duration))s \(track.bpm > 0 ? String(format:"%.1f BPM", track.bpm) : "sin BPM detectado")")
                    }
                    self.pushState()
                } catch {
                    let ns = error as NSError
                    self.log("[Error] Audio: \(ns.domain) \(ns.code) — \(ns.localizedDescription)")
                }
            }
        }
    }

    nonisolated static func copyToTemp(_ url: URL) -> URL? {
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sct-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private static func detectBPM(fromFileName url: URL) -> Double {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"(?<!\d)(\d{2,3})(?:\s*bpm|(?=\D|$))"#
        if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(name.startIndex..., in: name)
            for m in re.matches(in: name, range: range) {
                if let r = Range(m.range(at: 1), in: name), let v = Double(name[r]), v >= 60, v <= 220 {
                    return v
                }
            }
        }
        return 0
    }

    // MARK: - Playback

    func togglePlay(deck: Int) {
        if deck == 1 { playingA ? stopPlayer(deck: 1) : startPlayer(deck: 1) }
        else { playingB ? stopPlayer(deck: 2) : startPlayer(deck: 2) }
    }

    private func startPlayer(deck: Int) {
        let track = deck == 1 ? trackA : trackB
        guard let track else {
            log("[Error] Deck \(deck == 1 ? "A" : "B"): no hay pista cargada")
            return
        }
        let pos = deck == 1 ? posA : posB
        let player = deck == 1 ? audioA : audioB
        do {
            try player.play(from: pos * track.duration)
            if deck == 1 { playingA = true } else { playingB = true }
            pushState()
            log("[Play] Deck \(deck == 1 ? "A" : "B") — \(track.title)")
        } catch {
            let ns = error as NSError
            log("[Error] Play: \(ns.domain) \(ns.code) — \(ns.localizedDescription)")
            if deck == 1 { playingA = false } else { playingB = false }
            pushState()
        }
    }

    private func stopPlayer(deck: Int) {
        if deck == 1 {
            audioA.pauseKeepingPosition()
            playingA = false
        } else {
            audioB.pauseKeepingPosition()
            playingB = false
        }
        pushState()
    }

    func seek(deck: Int, fraction: Double) {
        let f = max(0, min(1, fraction))
        if deck == 1 {
            posA = f
            audioA.seek(seconds: f * (trackA?.duration ?? 0))
        } else {
            posB = f
            audioB.seek(seconds: f * (trackB?.duration ?? 0))
        }
        pushState()
    }

    func jogScrub(deck: Int, deltaSeconds: Double) {
        let dur = deck == 1 ? (trackA?.duration ?? 1) : (trackB?.duration ?? 1)
        guard dur > 0 else { return }
        if deck == 1 {
            let cur = audioA.isPlaying ? audioA.currentTime : posA * dur
            let t = max(0, min(dur, cur + deltaSeconds))
            posA = t / dur
            audioA.seek(seconds: t)
        } else {
            let cur = audioB.isPlaying ? audioB.currentTime : posB * dur
            let t = max(0, min(dur, cur + deltaSeconds))
            posB = t / dur
            audioB.seek(seconds: t)
        }
        pushState()
    }

    func adjustBPM(deck: Int, delta: Double) {
        if deck == 1 {
            let base = publishedBPM(deck: 1)
            bpmA = max(60, min(220, (base > 0 ? base : 120) + delta))
            trackA?.bpm = bpmA
        } else {
            let base = publishedBPM(deck: 2)
            bpmB = max(60, min(220, (base > 0 ? base : 120) + delta))
            trackB?.bpm = bpmB
        }
        pushState()
    }

    // MARK: - Cue

    func setCue(deck: Int) {
        let pos = deck == 1 ? posA * (trackA?.duration ?? 0) : posB * (trackB?.duration ?? 0)
        if deck == 1 { trackA?.cues.append(pos) }
        else { trackB?.cues.append(pos) }
    }

    func jumpCue(deck: Int, seconds: Double) {
        let dur = deck == 1 ? (trackA?.duration ?? 1) : (trackB?.duration ?? 1)
        seek(deck: deck, fraction: seconds / dur)
    }

    func deleteCue(deck: Int, seconds: Double) {
        if deck == 1 { trackA?.cues.removeAll { abs($0 - seconds) < 0.5 } }
        else { trackB?.cues.removeAll { abs($0 - seconds) < 0.5 } }
    }

    // MARK: - Network simulators

    func toggleDenon() {
        if denonRunning {
            denon?.stop(); denon = nil; denonRunning = false
        } else {
            let sim = DenonSimulator(log: { [weak self] msg in
                DispatchQueue.main.async { self?.log(msg) }
            })
            let cache = stateCache
            sim.stateProvider = { cache.read() }
            sim.start()
            denon = sim
            denonRunning = true
            pushState()
        }
    }

    func togglePioneer() {
        if pioneerRunning {
            pioneer?.stop(); pioneer = nil; pioneerRunning = false
            log("[Pioneer] Detenido")
        } else {
            let sim = PioneerSimulator(log: { [weak self] msg in
                DispatchQueue.main.async { self?.log(msg) }
            })
            let cache = stateCache
            sim.stateProvider = { cache.read() }
            sim.start()
            pioneer = sim
            pioneerRunning = true
            pushState()
            log("[Pioneer] Activo como CDJ-3000. STAGE CONNECT muestra título, BPM y waveform reales.")
        }
    }

    func log(_ msg: String) {
        logLines.append(msg)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    // MARK: - Audio analysis (nonisolated, runs on bg thread)

    nonisolated static func analyzeAudio(url: URL) async -> LoadedTrack? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        guard (try? file.read(into: buf)) != nil else { return nil }

        let duration = Double(frames) / fmt.sampleRate
        let samples = floatSamples(buf)
        var peaks = [Float](repeating: 0, count: 600)

        if let samples, !samples.isEmpty {
            let n = samples.count
            let bsz = max(1, n / 600)
            for i in 0..<600 {
                let s = i * bsz, e = min(s + bsz, n)
                var rms: Float = 0
                samples.withUnsafeBufferPointer { ptr in
                    vDSP_rmsqv(ptr.baseAddress!.advanced(by: s), 1, &rms, vDSP_Length(e - s))
                }
                peaks[i] = rms
            }
            let mx = peaks.max() ?? 1
            if mx > 0 { peaks = peaks.map { $0 / mx } }
        }

        let names = TrackNaming.parse(fileURL: url)
        let bpm = estimateBPM(samples: samples, sampleRate: fmt.sampleRate)
        return LoadedTrack(url: url, title: names.title, artist: names.artist,
                           duration: duration, peaks: peaks, cues: [], bpm: bpm, key: "")
    }

    /// Mezcla a mono float aunque el archivo sea int16/int32. Sin esto el BPM
    /// sale 0 en casi todo MP3/WAV de DJ (processingFormat no es float).
    nonisolated static func floatSamples(_ buf: AVAudioPCMBuffer) -> [Float]? {
        let n = Int(buf.frameLength)
        guard n > 0 else { return nil }
        let channels = max(1, Int(buf.format.channelCount))
        var out = [Float](repeating: 0, count: n)
        if let ch = buf.floatChannelData {
            if channels == 1 {
                out.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: ch[0], count: n)
                }
            } else {
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<channels { s += ch[c][i] }
                    out[i] = s / Float(channels)
                }
            }
            return out
        }
        if let ch = buf.int16ChannelData {
            let scale: Float = 1.0 / 32768.0
            let used = min(channels, 2)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<used { s += Float(ch[c][i]) * scale }
                out[i] = s / Float(used)
            }
            return out
        }
        if let ch = buf.int32ChannelData {
            let scale: Float = 1.0 / Float(Int32.max)
            let used = min(channels, 2)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<used { s += Float(ch[c][i]) * scale }
                out[i] = s / Float(used)
            }
            return out
        }
        return nil
    }

    nonisolated static func taggedBPM(url: URL) -> Double {
        taggedMetadata(url: url).bpm
    }

    nonisolated static func taggedMetadata(url: URL) -> (bpm: Double, key: String) {
        let asset = AVURLAsset(url: url)
        let items = asset.commonMetadata + asset.metadata
        var bpm: Double = 0
        var musKey = ""
        for item in items {
            let k = (item.commonKey?.rawValue ?? "").lowercased()
            let ident = item.identifier?.rawValue.lowercased() ?? ""
            let looksBPM = k.contains("bpm") || ident.contains("bpm") || ident.contains("tbpm")
                || ident.contains("beatspermin")
            let looksKey = ident.contains("tkey") || ident.contains("initialkey") || k == "key"
            if looksBPM && bpm == 0 {
                if let n = item.numberValue?.doubleValue, (60...220).contains(n) { bpm = n }
                else if let s = item.stringValue {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                    if let v = Double(t), (60...220).contains(v) { bpm = v }
                }
            }
            if looksKey && musKey.isEmpty {
                if let s = item.stringValue { musKey = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return (bpm, musKey)
    }

    nonisolated static func estimateBPM(samples: [Float]?, sampleRate: Double) -> Double {
        guard let samples, !samples.isEmpty, sampleRate > 0 else { return 0 }
        let hop = 512
        let maxSamples = min(samples.count, Int(sampleRate * 30))
        let nEnv = maxSamples / hop
        guard nEnv > 80 else { return 0 }
        var env = [Float](repeating: 0, count: nEnv)
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for i in 0..<nEnv {
                var rms: Float = 0
                vDSP_rmsqv(base.advanced(by: i * hop), 1, &rms, vDSP_Length(hop))
                env[i] = rms
            }
        }
        let mean = env.reduce(0, +) / Float(nEnv)
        env = env.map { max(0, $0 - mean) }
        let envRate = sampleRate / Double(hop)
        let minLag = max(1, Int(envRate * 60 / 180))
        let maxLag = min(nEnv - 2, Int(envRate * 60 / 70))
        guard maxLag > minLag else { return 0 }
        var bestLag = minLag
        var best: Float = 0
        var a = env
        var b = env
        for lag in minLag...maxLag {
            let n = vDSP_Length(nEnv - lag)
            var corr: Float = 0
            a.withUnsafeMutableBufferPointer { pa in
                b.withUnsafeMutableBufferPointer { pb in
                    vDSP_dotpr(pa.baseAddress!, 1, pb.baseAddress!.advanced(by: lag), 1, &corr, n)
                }
            }
            if corr > best {
                best = corr
                bestLag = lag
            }
        }
        let bpm = 60.0 * envRate / Double(bestLag)
        guard bpm >= 70, bpm <= 180, best > 0 else { return 0 }
        return (bpm * 100).rounded() / 100
    }
}

// MARK: - SimulatorView

struct SimulatorView: View {
    @EnvironmentObject var ctrl: SimulatorController

    var body: some View {
        VStack(spacing: 0) {
            AppHeader()
            Divider().background(Color.white.opacity(0.08))
            HStack(spacing: 1) {
                DeckPanel(deck: 1)
                Divider().background(Color.white.opacity(0.08))
                DeckPanel(deck: 2)
            }
            .frame(maxHeight: .infinity)
            Divider().background(Color.white.opacity(0.08))
            NetworkRow()
            Divider().background(Color.white.opacity(0.08))
            LogPanel()
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }
}

// MARK: - Header

private struct AppHeader: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("STAGE CONNECT TEST")
                    .font(.system(size: 13, weight: .black))
                    .tracking(1.8)
                    .foregroundColor(Color(red: 0.95, green: 0.65, blue: 0.1))
                Text("Simulador de reproductores — misma red que STAGE CONNECT")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("entikrecords.com")
                .font(.system(size: 10))
                .foregroundColor(Color.secondary.opacity(0.4))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

// MARK: - Deck Panel

private struct DeckPanel: View {
    let deck: Int
    @EnvironmentObject var ctrl: SimulatorController

    private var track: LoadedTrack? { deck == 1 ? ctrl.trackA : ctrl.trackB }
    private var pos: Double        { deck == 1 ? ctrl.posA    : ctrl.posB }
    private var playing: Bool      { deck == 1 ? ctrl.playingA : ctrl.playingB }
    private var bpm: Double        { deck == 1 ? ctrl.bpmA    : ctrl.bpmB }
    private var accent: Color      { deck == 1 ? Color(red:0.1,green:0.82,blue:0.5) : Color(red:0.25,green:0.6,blue:1) }

    var body: some View {
        VStack(spacing: 0) {
            // Label bar
            HStack {
                Circle().fill(playing ? accent : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
                    .animation(.easeInOut(duration: 0.25), value: playing)
                Text("DECK \(deck == 1 ? "A" : "B")")
                    .font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundColor(.secondary)
                Spacer()
                Text(playing ? "EN MARCHA" : (track != nil ? "PARADO" : "SIN PISTA"))
                    .font(.system(size: 9, weight: .bold)).tracking(0.5)
                    .foregroundColor(playing ? accent : .secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))

            // Waveform
            WaveformView(peaks: track?.peaks ?? [], pos: pos, cues: track?.cues ?? [],
                         duration: track?.duration ?? 0, accent: accent) { f in
                ctrl.seek(deck: deck, fraction: f)
            }
            .frame(height: 76)
            .padding(.horizontal, 8).padding(.top, 8)

            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.7))
                        .frame(width: g.size.width * CGFloat(pos))
                }
            }
            .frame(height: 3).padding(.horizontal, 8).padding(.top, 5)
            .transaction { $0.animation = nil }

            // Time
            HStack {
                Text(fmtTime(pos * (track?.duration ?? 0)))
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(accent)
                Spacer()
                if let d = track?.duration {
                    Text("-\(fmtTime((1-pos)*d))")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 4)
            .transaction { $0.animation = nil }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Sin pista")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(track != nil ? .white : .secondary).lineLimit(1)
                if let a = track?.artist, !a.isEmpty {
                    Text(a).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                if let k = track?.key, !k.isEmpty {
                    Text(k)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(accent.opacity(0.8))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.12)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 6)

            // BPM
            HStack(spacing: 6) {
                Button("-1") { ctrl.adjustBPM(deck: deck, delta: -1) }.buttonStyle(MiniBtn())
                Button("-0.1") { ctrl.adjustBPM(deck: deck, delta: -0.1) }.buttonStyle(MiniBtn())
                Text(String(format: "%.2f BPM", bpm))
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                Button("+0.1") { ctrl.adjustBPM(deck: deck, delta: +0.1) }.buttonStyle(MiniBtn())
                Button("+1") { ctrl.adjustBPM(deck: deck, delta: +1) }.buttonStyle(MiniBtn())
            }
            .padding(.horizontal, 10).padding(.top, 8)

            // Jog + Cues
            HStack(spacing: 14) {
                JogWheel(accent: accent, playing: playing) { delta in
                    // delta in points → ±0.04s per point (reasonable scrub speed)
                    ctrl.jogScrub(deck: deck, deltaSeconds: delta * 0.04)
                }
                VStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { i in
                        let cue: Double? = (track?.cues.indices.contains(i) == true) ? track!.cues[i] : nil
                        CueBtn(index: i, cue: cue, accent: accent) {
                            if let c = cue { ctrl.jumpCue(deck: deck, seconds: c) }
                            else { ctrl.setCue(deck: deck) }
                        } onDelete: {
                            if let c = cue { ctrl.deleteCue(deck: deck, seconds: c) }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 10)

            Spacer(minLength: 0)

            // Controls
            HStack(spacing: 10) {
                Button { ctrl.togglePlay(deck: deck) } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(playing ? Color.red.opacity(0.18) : accent.opacity(0.18)))
                        .foregroundColor(playing ? .red : accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { openFile() } label: {
                    Label("Abrir audio", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white.opacity(0.12))
            }
            .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openFile() {
        let p = NSOpenPanel()
        var types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        if let opus = UTType(filenameExtension: "opus") { types.append(opus) }
        if let ogg = UTType(filenameExtension: "ogg") { types.append(ogg) }
        if let caf = UTType(filenameExtension: "caf") { types.append(caf) }
        p.allowedContentTypes = types
        p.allowsMultipleSelection = false
        p.begin { r in
            if r == .OK, let url = p.url { ctrl.loadTrack(url: url, deck: deck) }
        }
    }

    private func fmtTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "--:--" }
        return String(format: "%02d:%02d", Int(s)/60, Int(s)%60)
    }
}

// MARK: - Waveform

private struct WaveformView: View {
    let peaks: [Float]
    let pos: Double
    let cues: [Double]
    let duration: Double
    let accent: Color
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = peaks.count
                guard n > 0 else {
                    ctx.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color.white.opacity(0.04)))
                    return
                }
                let maxBars = max(1, Int(size.width))
                let step = max(1, n / maxBars)
                let drawn = n / step
                let bw = size.width / CGFloat(drawn)
                let playX = CGFloat(pos) * size.width

                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color.black.opacity(0.35)))

                for j in 0..<drawn {
                    let i = min(n - 1, j * step)
                    let h = max(2, CGFloat(peaks[i]) * size.height * 0.9)
                    let x = CGFloat(j) * bw
                    let y = (size.height - h) / 2
                    let r = CGRect(x: x, y: y, width: max(1, bw - 0.6), height: h)
                    let past = x < playX
                    let amp = CGFloat(peaks[i])
                    let barColor: Color
                    if past {
                        // Gradiente de amplitud: azul -> cian -> verde -> amarillo -> rojo
                        if amp < 0.25 {
                            barColor = Color(red: 0.0, green: Double(amp / 0.25) * 0.7, blue: 1.0)
                        } else if amp < 0.5 {
                            let t = Double((amp - 0.25) / 0.25)
                            barColor = Color(red: 0.0, green: 0.7 + t * 0.3, blue: 1.0 - t)
                        } else if amp < 0.75 {
                            let t = Double((amp - 0.5) / 0.25)
                            barColor = Color(red: t, green: 1.0, blue: 0.0)
                        } else {
                            let t = Double((amp - 0.75) / 0.25)
                            barColor = Color(red: 1.0, green: 1.0 - t * 0.7, blue: 0.0)
                        }
                    } else {
                        barColor = Color(white: 0.22 + Double(amp) * 0.12)
                    }
                    ctx.fill(Path(r), with: .color(barColor))
                }

                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: playX, y: 0))
                    p.addLine(to: CGPoint(x: playX, y: size.height))
                }, with: .color(.white), lineWidth: 1.5)

                for c in cues where duration > 0 {
                    let cx = CGFloat(c / duration) * size.width
                    var t = Path()
                    t.move(to: CGPoint(x: cx, y: 0))
                    t.addLine(to: CGPoint(x: cx - 5, y: 9))
                    t.addLine(to: CGPoint(x: cx + 5, y: 9))
                    t.closeSubpath()
                    ctx.fill(t, with: .color(.yellow))
                }
            }
            .transaction { $0.animation = nil }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(Double(max(0, min(1, v.location.x / geo.size.width))))
            })
        }
        .cornerRadius(4)
    }
}

// MARK: - Jog Wheel

private struct JogWheel: View {
    let accent: Color
    let playing: Bool
    let onDrag: (Double) -> Void   // signed points

    @State private var angle: Double = 0
    @State private var lastTX: CGFloat? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.11, green: 0.11, blue: 0.15))
                .overlay(Circle().stroke(accent.opacity(playing ? 0.65 : 0.2), lineWidth: 2))

            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 8)
                .padding(14)

            // Indicator dot
            Circle().fill(accent).frame(width: 5, height: 5)
                .offset(y: -28)
                .rotationEffect(.degrees(angle))

            Text("JOG")
                .font(.system(size: 8, weight: .bold)).tracking(1)
                .foregroundColor(Color.secondary.opacity(0.4))
        }
        .frame(width: 84, height: 84)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let tx = v.translation.width
                    let delta = tx - (lastTX ?? tx)
                    lastTX = tx
                    if abs(delta) > 0 {
                        angle += delta * 3
                        onDrag(Double(delta))
                    }
                }
                .onEnded { _ in lastTX = nil }
        )
    }
}

// MARK: - Cue Button

private struct CueBtn: View {
    let index: Int
    let cue: Double?
    let accent: Color
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text("Q\(index+1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(cue != nil ? .black : accent)
                if let c = cue {
                    Text(String(format: "%02d:%02d", Int(c)/60, Int(c)%60))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.black.opacity(0.7))
                }
            }
            .frame(minWidth: 64, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(cue != nil ? accent : accent.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.4), lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .contextMenu { if cue != nil { Button("Borrar", role: .destructive, action: onDelete) } }
    }
}

// MARK: - Network Row

private struct NetworkRow: View {
    @EnvironmentObject var ctrl: SimulatorController

    var body: some View {
        HStack(spacing: 10) {
            Text("RED")
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundColor(.secondary)
            NetBtn(label: "Denon SC6000", sub: "StageLinq · 2 decks",
                   on: ctrl.denonRunning, color: Color(red:0.95,green:0.65,blue:0.1)) { ctrl.toggleDenon() }
            NetBtn(label: "Pioneer CDJ-3000", sub: "Pro DJ Link · solo con pista en A",
                   on: ctrl.pioneerRunning, color: Color(red:0.25,green:0.6,blue:1)) { ctrl.togglePioneer() }
            Spacer()
            Text("Abre STAGE CONNECT en el mismo Mac")
                .font(.system(size: 9)).foregroundColor(Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color(red: 0.08, green: 0.08, blue: 0.11))
    }
}

private struct NetBtn: View {
    let label: String; let sub: String; let on: Bool; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(on ? color : Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 10, weight: .semibold))
                        .foregroundColor(on ? color : .primary)
                    Text(on ? "ACTIVO — detener" : sub)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(on ? color.opacity(0.1) : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(on ? color.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Log Panel

private struct LogPanel: View {
    @EnvironmentObject var ctrl: SimulatorController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("REGISTRO").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundColor(.secondary)
                Spacer()
                Button("Limpiar") { ctrl.logLines.removeAll() }
                    .font(.system(size: 9)).foregroundColor(.secondary).buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(ctrl.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                }
                .onChange(of: ctrl.logLines.count) { _ in
                    if let last = ctrl.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 88)
        .background(Color(red: 0.05, green: 0.05, blue: 0.07))
    }
}

// MARK: - Button styles

private struct MiniBtn: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
            .frame(width: 32, height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}
