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
    var peaks: [Float]
    var peaksLow: [Float]
    var peaksMid: [Float]
    var peaksHigh: [Float]
    var cues: [Double]
    var loopIn: Double?
    var loopOut: Double?
    var bpm: Double
    var key: String
    var genre: String
    var album: String
    var comment: String
    var artworkPath: String
    var artworkJPEG: String
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
    private let varispeed = AVAudioUnitVarispeed()
    private var pcmBuffer: AVAudioPCMBuffer?
    private var startFrame: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var lengthFrames: AVAudioFramePosition = 0
    private var rate: Float = 1

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
        engine.attach(varispeed)
        engine.connect(node, to: varispeed, format: nil)
        engine.connect(varispeed, to: engine.mainMixerNode, format: nil)
    }

    /// 1.0 = 0 %. El playhead de `currentTime` sigue en segundos de disco.
    func setRate(_ value: Float) {
        rate = max(0.5, min(2.0, value))
        varispeed.rate = rate
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
        engine.disconnectNodeOutput(varispeed)
        engine.connect(node, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        varispeed.rate = rate
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
    @Published var pitchA: Double = 0
    @Published var pitchB: Double = 0
    @Published var pitchRange: Double = 8
    @Published var syncA = false
    @Published var syncB = false
    @Published var cueA: Double = 0
    @Published var cueB: Double = 0

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
    private var keyMonitor: Any?

    init() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.syncPositions() }
        }
        RunLoop.main.add(t, forMode: .common)
        posTimer = t
        startKeyMonitor()
    }

    func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.isARepeat { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) || flags.contains(.control) { return event }
            if Self.isTyping() { return event }
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch ch {
            case "1": self.togglePlay(deck: 1); return nil
            case "2": self.togglePlay(deck: 2); return nil
            case "d": self.toggleDenon(); return nil
            case "p": self.togglePioneer(); return nil
            default: return event
            }
        }
    }

    private static func isTyping() -> Bool {
        guard let resp = NSApp.keyWindow?.firstResponder else { return false }
        return resp is NSTextView || resp is NSTextField || resp is NSText
    }

    /// BPM que sale por TestLink y por el simulador de red. Nunca 0 si hay pista
    /// y ya se analizó o el usuario lo tocó.
    private func publishedBPM(deck: Int) -> Double {
        let base = deck == 1
            ? MusicalClock.bpm(bpmA, trackA?.bpm ?? 0)
            : MusicalClock.bpm(bpmB, trackB?.bpm ?? 0)
        let pitch = deck == 1 ? pitchA : pitchB
        guard base > 0 else { return 0 }
        return base * (1.0 + pitch / 100.0)
    }

    private func applyPitch(deck: Int) {
        let pct = deck == 1 ? pitchA : pitchB
        let player = deck == 1 ? audioA : audioB
        player.setRate(Float(1.0 + pct / 100.0))
        pushState()
    }

    func setPitch(deck: Int, percent: Double) {
        let limit = pitchRange
        let v = max(-limit, min(limit, percent))
        if deck == 1 { pitchA = v } else { pitchB = v }
        applyPitch(deck: deck)
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
                    key: trackA?.key ?? "",
                    genre: trackA?.genre ?? "",
                    album: trackA?.album ?? "",
                    comment: trackA?.comment ?? "",
                    peaksLow: TestLinkDeck.quantize(trackA?.peaksLow ?? []),
                    peaksMid: TestLinkDeck.quantize(trackA?.peaksMid ?? []),
                    peaksHigh: TestLinkDeck.quantize(trackA?.peaksHigh ?? []),
                    artworkPath: trackA?.artworkPath ?? "",
                    artworkJPEG: trackA?.artworkJPEG ?? "",
                    cues: trackA?.cues ?? [],
                    loopIn: trackA?.loopIn ?? -1,
                    loopOut: trackA?.loopOut ?? -1,
                    pitch: pitchA,
                    isSync: syncA
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
                    key: trackB?.key ?? "",
                    genre: trackB?.genre ?? "",
                    album: trackB?.album ?? "",
                    comment: trackB?.comment ?? "",
                    peaksLow: TestLinkDeck.quantize(trackB?.peaksLow ?? []),
                    peaksMid: TestLinkDeck.quantize(trackB?.peaksMid ?? []),
                    peaksHigh: TestLinkDeck.quantize(trackB?.peaksHigh ?? []),
                    artworkPath: trackB?.artworkPath ?? "",
                    artworkJPEG: trackB?.artworkJPEG ?? "",
                    cues: trackB?.cues ?? [],
                    loopIn: trackB?.loopIn ?? -1,
                    loopOut: trackB?.loopOut ?? -1,
                    pitch: pitchB,
                    isSync: syncB
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
                key: trackA?.key ?? "",
                pitchPercent: pitchA,
                isSync: syncA),
            SimDeckState(
                title: trackB?.title ?? "",
                artist: trackB?.artist ?? "",
                bpm: trackB == nil ? 0 : publishedBPM(deck: 2),
                isPlaying: playingB,
                positionSeconds: posB * (trackB?.duration ?? 0),
                duration: trackB?.duration ?? 0,
                isMaster: playingB && !playingA,
                key: trackB?.key ?? "",
                pitchPercent: pitchB,
                isSync: syncB)
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
                if track.key.isEmpty {
                    track.key = MusicalKey.resolved(raw: "", title: track.title, artist: track.artist)
                }
                if !tagged.genre.isEmpty { track.genre = tagged.genre }
                if !tagged.album.isEmpty { track.album = tagged.album }
                if !tagged.comment.isEmpty { track.comment = tagged.comment }
                if track.artworkPath.isEmpty || track.artworkJPEG.isEmpty {
                    let art = Self.extractArtwork(url: imported)
                    if track.artworkPath.isEmpty { track.artworkPath = art.path }
                    if track.artworkJPEG.isEmpty { track.artworkJPEG = art.jpeg }
                }
                do {
                    if deck == 1 {
                        self.audioA.stopAndReset()
                        try self.audioA.load(url: imported)
                        self.trackA = track
                        self.posA = 0
                        self.playingA = false
                        self.bpmA = track.bpm
                        self.log("[Deck A] \(track.title) — \(String(format:"%.1f",track.duration))s \(track.bpm > 0 ? String(format:"%.1f BPM", track.bpm) : "sin BPM detectado")\(track.artworkPath.isEmpty && track.artworkJPEG.isEmpty ? "" : " · portada")")
                    } else {
                        self.audioB.stopAndReset()
                        try self.audioB.load(url: imported)
                        self.trackB = track
                        self.posB = 0
                        self.playingB = false
                        self.bpmB = track.bpm
                        self.log("[Deck B] \(track.title) — \(String(format:"%.1f",track.duration))s \(track.bpm > 0 ? String(format:"%.1f BPM", track.bpm) : "sin BPM detectado")\(track.artworkPath.isEmpty && track.artworkJPEG.isEmpty ? "" : " · portada")")
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
        pushState()
    }

    func setLoopIn(deck: Int) {
        let pos = deck == 1 ? posA * (trackA?.duration ?? 0) : posB * (trackB?.duration ?? 0)
        if deck == 1 { trackA?.loopIn = pos }
        else { trackB?.loopIn = pos }
        normalizeLoop(deck: deck)
        pushState()
    }

    func setLoopOut(deck: Int) {
        let pos = deck == 1 ? posA * (trackA?.duration ?? 0) : posB * (trackB?.duration ?? 0)
        if deck == 1 { trackA?.loopOut = pos }
        else { trackB?.loopOut = pos }
        normalizeLoop(deck: deck)
        pushState()
    }

    func clearLoop(deck: Int) {
        if deck == 1 { trackA?.loopIn = nil; trackA?.loopOut = nil }
        else { trackB?.loopIn = nil; trackB?.loopOut = nil }
        pushState()
    }

    private func normalizeLoop(deck: Int) {
        if deck == 1, let a = trackA?.loopIn, let b = trackA?.loopOut, b < a {
            trackA?.loopIn = b
            trackA?.loopOut = a
        }
        if deck == 2, let a = trackB?.loopIn, let b = trackB?.loopOut, b < a {
            trackB?.loopIn = b
            trackB?.loopOut = a
        }
    }

    func jumpCue(deck: Int, seconds: Double) {
        let dur = deck == 1 ? (trackA?.duration ?? 1) : (trackB?.duration ?? 1)
        seek(deck: deck, fraction: seconds / dur)
    }

    func deleteCue(deck: Int, seconds: Double) {
        if deck == 1 { trackA?.cues.removeAll { abs($0 - seconds) < 0.5 } }
        else { trackB?.cues.removeAll { abs($0 - seconds) < 0.5 } }
        pushState()
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
            log("[Pioneer] Activo como CDJ-3000")
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
        var peaks: [Float] = []
        var peaksLow: [Float] = []
        var peaksMid: [Float] = []
        var peaksHigh: [Float] = []

        if let samples, !samples.isEmpty {
            let rgb = analyzeBands(samples: samples, sampleRate: fmt.sampleRate)
            peaks = rgb.amp
            peaksLow = rgb.low
            peaksMid = rgb.mid
            peaksHigh = rgb.high
        }

        let names = TrackNaming.parse(fileURL: url)
        let bpm = estimateBPM(samples: samples, sampleRate: fmt.sampleRate)
        let art = extractArtwork(url: url)
        return LoadedTrack(url: url, title: names.title, artist: names.artist,
                           duration: duration, peaks: peaks, peaksLow: peaksLow,
                           peaksMid: peaksMid, peaksHigh: peaksHigh, cues: [],
                           loopIn: nil, loopOut: nil, bpm: bpm, key: "",
                           genre: "", album: "", comment: "",
                           artworkPath: art.path, artworkJPEG: art.jpeg)
    }

    /// Portada embebida (AVAsset, ID3 APIC, iTunes covr, AIFF). JPEG válido + miniatura.
    nonisolated static func extractArtwork(url: URL) -> (path: String, jpeg: String) {
        var raw: Data?
        if let fromAsset = artworkDataFromAsset(url: url) { raw = fromAsset }
        if raw == nil { raw = artworkDataFromID3(url: url) }
        if raw == nil { raw = artworkDataFromM4A(url: url) }
        guard let raw, let imageData = unwrapImageData(raw), let image = NSImage(data: imageData) else {
            return ("", "")
        }
        let dir = StageConnectArtworkStore.writableDirectory()
        let dest = dir.appendingPathComponent("sct-art-\(abs(url.path.hashValue)).jpg")
        let full = jpegData(from: image, maxEdge: 400, quality: 0.78)
        if let full { try? full.write(to: dest, options: .atomic) }
        let path = FileManager.default.fileExists(atPath: dest.path) ? dest.path : ""
        let jpeg = boundedArtworkJPEG(from: image)
        return (path, jpeg)
    }

    /// Miniatura que cabe en TestLink (`maxArtworkJPEGChars`) y se pinta si la ruta falla.
    nonisolated static func boundedArtworkJPEG(from image: NSImage) -> String {
        let attempts: [(CGFloat, CGFloat)] = [(72, 0.55), (56, 0.48), (40, 0.40)]
        for (edge, quality) in attempts {
            guard let data = jpegData(from: image, maxEdge: edge, quality: quality) else { continue }
            let b64 = data.base64EncodedString()
            if b64.count <= TestLinkDeck.maxArtworkJPEGChars { return b64 }
        }
        return ""
    }

    nonisolated static func extractArtworkPath(url: URL) -> String {
        extractArtwork(url: url).path
    }

    nonisolated private static func artworkDataFromAsset(url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["commonMetadata", "metadata"]) {
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
        for item in asset.commonMetadata + asset.metadata {
            let ident = item.identifier?.rawValue.lowercased() ?? ""
            let isArt = item.commonKey == .commonKeyArtwork
                || ident.contains("artwork") || ident.contains("covr")
                || ident.contains("apic") || ident.contains("picture")
            guard isArt else { continue }
            if let d = item.dataValue, d.count > 32 { return d }
            if let d = item.value as? Data, d.count > 32 { return d }
            if let img = item.value as? NSImage, let tiff = img.tiffRepresentation { return tiff }
        }
        return nil
    }

    nonisolated private static func unwrapImageData(_ data: Data) -> Data? {
        if data.count > 4, data[0] == 0xFF, data[1] == 0xD8 { return data }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        if data.count > 8 {
            let s4 = data.dropFirst(4)
            if s4.starts(with: [0xFF, 0xD8]) || s4.starts(with: [0x89, 0x50]) { return Data(s4) }
            let s8 = data.dropFirst(8)
            if s8.starts(with: [0xFF, 0xD8]) || s8.starts(with: [0x89, 0x50]) { return Data(s8) }
        }
        if let r = data.range(of: Data([0xFF, 0xD8, 0xFF])) { return Data(data[r.lowerBound...]) }
        if let r = data.range(of: Data([0x89, 0x50, 0x4E, 0x47])) { return Data(data[r.lowerBound...]) }
        return NSImage(data: data) != nil ? data : nil
    }

    nonisolated private static func jpegData(from image: NSImage, maxEdge: CGFloat, quality: CGFloat) -> Data? {
        guard let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        let scale = min(1, maxEdge / max(CGFloat(src.width), CGFloat(src.height), 1))
        let nw = max(1, Int(CGFloat(src.width) * scale))
        let nh = max(1, Int(CGFloat(src.height) * scale))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out)
            .representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    nonisolated private static func artworkDataFromID3(url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count > 16 else { return nil }
        if data.starts(with: [0x49, 0x44, 0x33]) {
            return parseID3APIC(data)
        }
        if let range = data.range(of: Data([0x49, 0x44, 0x33])), range.lowerBound > 0 {
            return parseID3APIC(data.subdata(in: range.lowerBound..<data.count))
        }
        return nil
    }

    nonisolated private static func parseID3APIC(_ data: Data) -> Data? {
        guard data.count > 10, data.starts(with: [0x49, 0x44, 0x33]) else { return nil }
        let ver = data[3]
        let unsyncSize: Int = {
            let b = data[6], c = data[7], d = data[8], e = data[9]
            return ((Int(b) & 0x7F) << 21) | ((Int(c) & 0x7F) << 14) | ((Int(d) & 0x7F) << 7) | (Int(e) & 0x7F)
        }()
        var i = 10
        if data[5] & 0x40 != 0, i + 4 <= data.count {
            let ext: Int
            if ver >= 4 {
                let b = data[i], c = data[i+1], d = data[i+2], e = data[i+3]
                ext = ((Int(b) & 0x7F) << 21) | ((Int(c) & 0x7F) << 14) | ((Int(d) & 0x7F) << 7) | (Int(e) & 0x7F)
            } else {
                ext = Int(data[i]) << 24 | Int(data[i+1]) << 16 | Int(data[i+2]) << 8 | Int(data[i+3])
            }
            i += max(4, ext)
        }
        let end = min(data.count, 10 + unsyncSize)
        while i + 10 < end {
            if ver == 2 {
                let id = String(bytes: data[i..<i+3], encoding: .ascii) ?? ""
                let size = Int(data[i+3]) << 16 | Int(data[i+4]) << 8 | Int(data[i+5])
                i += 6
                guard size > 0, i + size <= data.count else { break }
                if id == "PIC" { return unwrapImageData(data.subdata(in: i..<i+size)) }
                i += size
                continue
            }
            let id = String(bytes: data[i..<i+4], encoding: .ascii) ?? ""
            let size: Int
            if ver >= 4 {
                let b = data[i+4], c = data[i+5], d = data[i+6], e = data[i+7]
                size = ((Int(b) & 0x7F) << 21) | ((Int(c) & 0x7F) << 14) | ((Int(d) & 0x7F) << 7) | (Int(e) & 0x7F)
            } else {
                size = Int(data[i+4]) << 24 | Int(data[i+5]) << 16 | Int(data[i+6]) << 8 | Int(data[i+7])
            }
            i += 10
            guard size > 0, i + size <= data.count else { break }
            if id == "APIC" {
                return apicPayload(data.subdata(in: i..<i+size))
            }
            i += size
        }
        return nil
    }

    nonisolated private static func apicPayload(_ payload: Data) -> Data? {
        guard payload.count > 8 else { return unwrapImageData(payload) }
        var i = 1
        while i < payload.count, payload[i] != 0 { i += 1 }
        i += 2
        guard i < payload.count else { return unwrapImageData(payload) }
        let enc = payload[0]
        if enc == 0 || enc == 3 {
            while i < payload.count, payload[i] != 0 { i += 1 }
            i += 1
        } else {
            while i + 1 < payload.count, !(payload[i] == 0 && payload[i+1] == 0) { i += 1 }
            i += 2
        }
        guard i < payload.count else { return unwrapImageData(payload) }
        return unwrapImageData(payload.subdata(in: i..<payload.count)) ?? unwrapImageData(payload)
    }

    nonisolated private static func artworkDataFromM4A(url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count > 16 else { return nil }
        return findAtom(data, name: "covr", from: 0, to: min(data.count, 8_000_000))
    }

    nonisolated private static func findAtom(_ data: Data, name: String, from: Int, to: Int) -> Data? {
        var i = from
        let needle = Array(name.utf8)
        let containers: Set<String> = ["moov", "udta", "meta", "ilst", "trak", "mdia"]
        while i + 8 <= to {
            let size = Int(data[i]) << 24 | Int(data[i+1]) << 16 | Int(data[i+2]) << 8 | Int(data[i+3])
            guard size >= 8, i + size <= data.count else { break }
            let four = String(bytes: data[i+4..<i+8], encoding: .ascii) ?? ""
            if data[i+4] == needle[0], data[i+5] == needle[1],
               data[i+6] == needle[2], data[i+7] == needle[3] {
                return unwrapImageData(data.subdata(in: i+8..<i+size))
            }
            if containers.contains(four) {
                let innerFrom = four == "meta" ? i + 12 : i + 8
                if let inner = findAtom(data, name: name, from: innerFrom, to: min(i + size, to)) {
                    return inner
                }
            }
            i += size
        }
        return nil
    }

    /// Crossover complementario: low <250 Hz, mid 250–4 kHz, high >4 kHz.
    /// RMS + pico por columna; ~12000 columnas reales del audio.
    nonisolated static func analyzeBands(samples: [Float], sampleRate: Double) -> (amp: [Float], low: [Float], mid: [Float], high: [Float]) {
        let n = samples.count
        let target = TestLinkDeck.waveformColumns
        let minHop = max(1, Int(sampleRate * 0.003))
        let hop = max(minHop, max(1, n / target))
        let count = max(64, min(target, (n + hop - 1) / hop))
        let aLow = Float(1 - exp(-2.0 * Double.pi * 250.0 / max(1, sampleRate)))
        let aSplit = Float(1 - exp(-2.0 * Double.pi * 4000.0 / max(1, sampleRate)))

        var lowOut = [Float](repeating: 0, count: count)
        var midOut = [Float](repeating: 0, count: count)
        var highOut = [Float](repeating: 0, count: count)

        samples.withUnsafeBufferPointer { ptr in
            guard let src = ptr.baseAddress else { return }
            var zLow: Float = 0
            var zLP4k: Float = 0
            var idx = 0
            var i = 0
            while i < n && idx < count {
                let end = min(i + hop, n)
                let len = end - i
                var lowSq: Float = 0
                var midSq: Float = 0
                var highSq: Float = 0
                var lowPk: Float = 0
                var midPk: Float = 0
                var highPk: Float = 0
                var s = i
                while s < end {
                    let x = src[s]
                    zLow += aLow * (x - zLow)
                    zLP4k += aSplit * (x - zLP4k)
                    let low = zLow
                    let mid = zLP4k - zLow
                    let high = x - zLP4k
                    let al = abs(low)
                    let am = abs(mid)
                    let ah = abs(high)
                    lowSq += al * al
                    midSq += am * am
                    highSq += ah * ah
                    if al > lowPk { lowPk = al }
                    if am > midPk { midPk = am }
                    if ah > highPk { highPk = ah }
                    s += 1
                }
                let inv = 1 / Float(max(1, len))
                lowOut[idx] = 0.55 * lowPk + 0.45 * sqrt(lowSq * inv)
                midOut[idx] = (0.55 * midPk + 0.45 * sqrt(midSq * inv)) * 1.20
                highOut[idx] = (0.55 * highPk + 0.45 * sqrt(highSq * inv)) * 1.70
                idx += 1
                i = end
            }
            if idx < count {
                lowOut.removeLast(count - idx)
                midOut.removeLast(count - idx)
                highOut.removeLast(count - idx)
            }
        }

        var mx: Float = 0.0001
        for v in lowOut where v > mx { mx = v }
        for v in midOut where v > mx { mx = v }
        for v in highOut where v > mx { mx = v }
        let scale = 1 / mx
        var amp = [Float](repeating: 0, count: lowOut.count)
        for i in lowOut.indices {
            let lo = min(1, lowOut[i] * scale)
            let md = min(1, midOut[i] * scale)
            let hi = min(1, highOut[i] * scale)
            lowOut[i] = lo
            midOut[i] = md
            highOut[i] = hi
            amp[i] = max(lo, md, hi)
        }
        return (amp, lowOut, midOut, highOut)
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

    nonisolated static func taggedMetadata(url: URL) -> (bpm: Double, key: String, genre: String, album: String, comment: String) {
        let asset = AVURLAsset(url: url)
        let items = asset.commonMetadata + asset.metadata
        var bpm: Double = 0
        var musKey = ""
        var genre = ""
        var album = ""
        var comment = ""
        for item in items {
            let k = (item.commonKey?.rawValue ?? "").lowercased()
            let ident = item.identifier?.rawValue.lowercased() ?? ""
            let looksBPM = k.contains("bpm") || ident.contains("bpm") || ident.contains("tbpm")
                || ident.contains("beatspermin")
            let looksKey = ident.contains("tkey") || ident.contains("initialkey") || k == "key"
            let looksGenre = k.contains("type") || ident.contains("genre") || ident.contains("tcon")
            let looksAlbum = k.contains("album") || ident.contains("talb") || ident.contains("albumname")
            let looksComment = k.contains("comment") || ident.contains("comm") || ident.contains("description")
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
            if looksGenre && genre.isEmpty {
                if let s = item.stringValue { genre = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if looksAlbum && album.isEmpty {
                if let s = item.stringValue { album = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if looksComment && comment.isEmpty {
                if let s = item.stringValue { comment = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return (bpm, musKey, genre, album, comment)
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
                Text("Denon y Pioneer · misma red que STAGE CONNECT")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("entikrecords.com")
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondary.opacity(0.4))
                    Text("1/2 play  ·  D Denon  ·  P Pioneer")
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary.opacity(0.35))
                }
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
    private var pitch: Double      { deck == 1 ? ctrl.pitchA  : ctrl.pitchB }
    private var accent: Color      { deck == 1 ? Color(red:0.1,green:0.82,blue:0.5) : Color(red:0.25,green:0.6,blue:1) }
    private var effectiveBPM: Double {
        bpm > 0 ? bpm * (1.0 + pitch / 100.0) : 0
    }

    private var pitchRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text("PITCH")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundColor(.secondary)
                Text(String(format: "%+.2f%%", pitch))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                Text(effectiveBPM > 0 ? String(format: "%.2f eBPM", effectiveBPM) : "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                ForEach([8.0, 10.0, 16.0], id: \.self) { r in
                    Button("±\(Int(r))") { ctrl.pitchRange = r; ctrl.setPitch(deck: deck, percent: pitch) }
                        .buttonStyle(MiniBtn())
                        .opacity(ctrl.pitchRange == r ? 1 : 0.45)
                }
                Button("0") { ctrl.setPitch(deck: deck, percent: 0) }.buttonStyle(MiniBtn())
            }
            Slider(value: Binding(
                get: { pitch },
                set: { ctrl.setPitch(deck: deck, percent: $0) }
            ), in: -ctrl.pitchRange...ctrl.pitchRange)
            .tint(accent)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

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
                Text(playing ? "PLAY" : (track != nil ? "STOP" : "SIN PISTA"))
                    .font(.system(size: 9, weight: .bold)).tracking(0.5)
                    .foregroundColor(playing ? accent : .secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))

            // Waveform
            WaveformView(peaks: track?.peaks ?? [],
                         peaksLow: track?.peaksLow ?? [],
                         peaksMid: track?.peaksMid ?? [],
                         peaksHigh: track?.peaksHigh ?? [],
                         pos: pos, cues: track?.cues ?? [],
                         loopIn: track?.loopIn,
                         loopOut: track?.loopOut,
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

            pitchRow

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
                    HStack(spacing: 4) {
                        Button("IN") { ctrl.setLoopIn(deck: deck) }
                            .buttonStyle(MiniBtn())
                            .help("Loop in en la posicion actual")
                        Button("OUT") { ctrl.setLoopOut(deck: deck) }
                            .buttonStyle(MiniBtn())
                            .help("Loop out en la posicion actual")
                        if track?.loopIn != nil || track?.loopOut != nil {
                            Button("X") { ctrl.clearLoop(deck: deck) }
                                .buttonStyle(MiniBtn())
                                .help("Quitar loop")
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
    var peaksLow: [Float] = []
    var peaksMid: [Float] = []
    var peaksHigh: [Float] = []
    let pos: Double
    let cues: [Double]
    var loopIn: Double? = nil
    var loopOut: Double? = nil
    let duration: Double
    let accent: Color
    let onSeek: (Double) -> Void

    private var hasRGB: Bool {
        let n = peaksLow.count
        return n > 1 && peaksMid.count == n && peaksHigh.count == n
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = hasRGB ? peaksLow.count : peaks.count
                guard n > 0 else {
                    ctx.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color.white.opacity(0.04)))
                    return
                }
                let cols = max(1, Int(size.width / 0.50))
                let bw = size.width / CGFloat(cols)
                let playX = CGFloat(pos) * size.width
                let midY = size.height / 2
                let maxH = size.height * 0.46

                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color.black))
                ctx.fill(Path(CGRect(x: 0, y: midY - 0.4, width: size.width, height: 0.8)),
                         with: .color(Color.white.opacity(0.10)))

                if let inn = loopIn, let out = loopOut, duration > 0, inn < out {
                    let x1 = CGFloat(inn / duration) * size.width
                    let x2 = CGFloat(out / duration) * size.width
                    ctx.fill(Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1), height: size.height)),
                             with: .color(Color.green.opacity(0.16)))
                    ctx.fill(Path(CGRect(x: x1, y: 0, width: 1.5, height: size.height)),
                             with: .color(Color.green.opacity(0.80)))
                    ctx.fill(Path(CGRect(x: x2 - 1.5, y: 0, width: 1.5, height: size.height)),
                             with: .color(Color.green.opacity(0.80)))
                }

                for j in 0..<cols {
                    let s = Int((Double(j) / Double(cols)) * Double(n))
                    let e = max(s + 1, Int((Double(j + 1) / Double(cols)) * Double(n)))
                    let x = CGFloat(j) * bw
                    let fade: Double = x < playX ? 1.0 : 0.70
                    if hasRGB {
                        var lo: Float = 0, md: Float = 0, hi: Float = 0
                        var i = s
                        while i < e && i < n {
                            lo = max(lo, peaksLow[i])
                            md = max(md, peaksMid[i])
                            hi = max(hi, peaksHigh[i])
                            i += 1
                        }
                        drawRGB(ctx: ctx, x: x, bw: bw, midY: midY, maxH: maxH,
                                low: lo, mid: md, high: hi, fade: fade)
                    } else {
                        var amp: Float = 0
                        var i = s
                        while i < e && i < n {
                            amp = max(amp, peaks[i])
                            i += 1
                        }
                        let h = max(1, CGFloat(amp) * maxH)
                        var g = ctx
                        g.opacity = fade
                        let color = Color(red: 0.22, green: 0.82, blue: 1.00)
                        g.fill(Path(CGRect(x: x, y: midY - h, width: max(0.7, bw - 0.35), height: h)), with: .color(color))
                        g.opacity = fade * 0.88
                        g.fill(Path(CGRect(x: x, y: midY, width: max(0.7, bw - 0.35), height: h)), with: .color(color))
                    }
                }

                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: playX, y: 0))
                    p.addLine(to: CGPoint(x: playX, y: size.height))
                }, with: .color(.white), lineWidth: 1.5)

                for c in cues where duration > 0 {
                    let cx = CGFloat(c / duration) * size.width
                    var line = Path()
                    line.move(to: CGPoint(x: cx, y: 0))
                    line.addLine(to: CGPoint(x: cx, y: size.height))
                    ctx.stroke(line, with: .color(Color.orange.opacity(0.90)), lineWidth: 1.5)
                    var t = Path()
                    t.move(to: CGPoint(x: cx, y: 0))
                    t.addLine(to: CGPoint(x: cx - 5, y: 9))
                    t.addLine(to: CGPoint(x: cx + 5, y: 9))
                    t.closeSubpath()
                    ctx.fill(t, with: .color(.orange))
                }
            }
            .transaction { $0.animation = nil }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(Double(max(0, min(1, v.location.x / geo.size.width))))
            })
        }
        .cornerRadius(4)
    }

    private func drawRGB(ctx: GraphicsContext, x: CGFloat, bw: CGFloat, midY: CGFloat, maxH: CGFloat,
                         low: Float, mid: Float, high: Float, fade: Double) {
        struct Layer { var h: CGFloat; var r: Double; var g: Double; var b: Double }
        var layers = [
            Layer(h: CGFloat(low) * maxH,  r: 1.00, g: 0.30, b: 0.05),
            Layer(h: CGFloat(mid) * maxH,  r: 0.20, g: 0.95, b: 0.12),
            Layer(h: CGFloat(high) * maxH, r: 0.10, g: 0.55, b: 1.00),
        ]
        layers.sort { $0.h < $1.h }
        let barW = max(0.32, bw - 0.12)
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
            gc.fill(Path(CGRect(x: x, y: midY - h, width: barW, height: dh)), with: .color(color))
            gc.opacity = fade * 0.90
            gc.fill(Path(CGRect(x: x, y: midY + prev, width: barW, height: dh)), with: .color(color))
            prev = h
        }
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
            NetBtn(label: "Pioneer CDJ-3000", sub: "Pro DJ Link",
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
