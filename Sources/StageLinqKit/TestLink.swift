// TestLink.swift
// Canal local UDP 127.0.0.1:51341 entre STAGE CONNECT TEST y STAGE CONNECT.
// StageLinq y Pro DJ Link no llevan waveform ni, en Pioneer, título de pista.
// TEST publica título limpio, BPM, posición y picos RMS; la app principal
// los superpone en las filas Denon/Pioneer de este Mac.

import Foundation
import Combine

public enum TrackNaming {
    /// Quita el prefijo de copia temporal `stage-connect-test-<uuid>-`.
    public static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^stage-connect-test-[0-9A-Fa-f-]{36}-"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        if s.lowercased().hasPrefix("sct-"), s.count > 40 {
            if let idx = s.lastIndex(of: "-") {
                let rest = String(s[s.index(after: idx)...])
                if !rest.isEmpty { s = rest }
            }
        }
        let banned = ["stage connect test", "stage-connect-test", "sc6000-sim", "stage connect"]
        if banned.contains(s.lowercased()) { return "" }
        return s
    }

    public static func parse(fileURL: URL) -> (title: String, artist: String) {
        let name = cleanTitle(fileURL.deletingPathExtension().lastPathComponent)
        let parts = name.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            return (title, artist)
        }
        return (name, "")
    }
}

public struct TestLinkDeck: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var bpm: Double
    public var playing: Bool
    public var position: Double
    public var duration: Double
    public var peaks: [UInt8]
    public var isMaster: Bool
    public var key: String

    public init(title: String = "", artist: String = "", bpm: Double = 0,
                playing: Bool = false, position: Double = 0, duration: Double = 0,
                peaks: [UInt8] = [], isMaster: Bool = false, key: String = "") {
        self.title = TrackNaming.cleanTitle(title)
        self.artist = artist
        self.bpm = bpm
        self.playing = playing
        self.position = position
        self.duration = duration
        self.peaks = peaks
        self.isMaster = isMaster
        self.key = key
    }

    public var peaksFloat: [Float] {
        peaks.map { Float($0) / 255.0 }
    }

    public var progress: Double? {
        guard duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    public var loaded: Bool { duration > 0 || !title.isEmpty }

    public static func quantize(_ peaks: [Float], count: Int = 300) -> [UInt8] {
        guard !peaks.isEmpty else { return [] }
        if peaks.count == count {
            return peaks.map { UInt8(min(255, max(0, Int(($0 * 255).rounded())))) }
        }
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let src = Int((Double(i) / Double(count)) * Double(peaks.count))
            let v = peaks[min(peaks.count - 1, src)]
            out[i] = UInt8(min(255, max(0, Int((v * 255).rounded()))))
        }
        return out
    }
}

public struct TestLinkSnapshot: Codable, Equatable, Sendable {
    public var denonOn: Bool
    public var pioneerOn: Bool
    public var decks: [TestLinkDeck]

    public init(denonOn: Bool = false, pioneerOn: Bool = false, decks: [TestLinkDeck] = []) {
        self.denonOn = denonOn
        self.pioneerOn = pioneerOn
        self.decks = decks
    }

    public func deck(_ index: Int) -> TestLinkDeck? {
        guard index >= 0, index < decks.count else { return nil }
        let d = decks[index]
        return d.loaded ? d : nil
    }

    public func firstLoadedDeck() -> TestLinkDeck? {
        decks.first { $0.loaded }
    }
}

/// Foto estable de qué hay cargado. ContentView la usa para el ForEach;
/// el snapshot a 60 Hz solo mueve playhead/BPM dentro de cada fila.
public struct TestLinkRoster: Equatable, Sendable {
    public var denonOn: Bool = false
    public var pioneerOn: Bool = false
    public var loadedLayers: [Bool] = [false, false]

    public var denonLoadedCount: Int {
        guard denonOn else { return 0 }
        return loadedLayers.filter { $0 }.count
    }

    public var hasPioneerTrack: Bool {
        pioneerOn && loadedLayers.contains(true)
    }

    public func layerLoaded(_ index: Int) -> Bool {
        guard index >= 0, index < loadedLayers.count else { return false }
        return loadedLayers[index]
    }
}

/// Primera fuente con BPM usable. Nunca sustituye 0 por un dummy 120.
public enum MusicalClock {
    public static func bpm(_ candidates: Double...) -> Double {
        candidates.first { $0 > 0 && $0.isFinite } ?? 0
    }

    public static func beatInBar(position: Double, bpm: Double) -> Int {
        guard bpm > 20, position >= 0 else { return 0 }
        let beat = position * bpm / 60.0
        return Int(beat.truncatingRemainder(dividingBy: 4)) + 1
    }

    public static func beatCount(position: Double, bpm: Double) -> Int {
        guard bpm > 20, position >= 0 else { return 0 }
        return Int(position * bpm / 60.0)
    }
}

public enum TestLink {
    public static let port: UInt16 = 51341
    public static let host = "127.0.0.1"
}

public final class TestLinkPublisher {
    private let sock: UDPSocket?
    private var lastPeakSignature: [String] = []

    public init() {
        sock = try? UDPSocket(listenPort: nil)
    }

    public func send(_ snapshot: TestLinkSnapshot) {
        guard let sock else { return }
        var frame = snapshot
        let sig = snapshot.decks.map { "\($0.title)|\($0.peaks.count)" }
        if sig == lastPeakSignature {
            frame.decks = frame.decks.map { d in
                var c = d
                c.peaks = []
                return c
            }
        } else {
            lastPeakSignature = sig
        }
        guard let data = try? JSONEncoder().encode(frame) else { return }
        sock.send(data, to: TestLink.host, port: TestLink.port)
    }
}

public final class TestLinkReceiver: ObservableObject {
    @Published public private(set) var snapshot: TestLinkSnapshot?
    @Published public private(set) var roster = TestLinkRoster()
    /// Solo cambia cuando entra/sale Denon/Pioneer o se carga/descarga una pista.
    /// ContentView usa esto para no reconstruir la lista 60 veces por segundo.
    @Published public private(set) var rosterTick: UInt64 = 0

    private var sock: UDPSocket?
    private var stopped = false
    private let queue = DispatchQueue(label: "com.entikrecords.stageconnect.testlink", qos: .userInteractive)
    private var lastPeaks: [[UInt8]] = [[], []]
    private var lastBPM: [Double] = [0, 0]
    private var lastBPMTitle: [String] = ["", ""]
    private var lastHeard = Date.distantPast
    private var lastRosterKey = ""

    public init() {}

    public func start() {
        stopped = false
        queue.async { [weak self] in self?.run() }
        queue.async { [weak self] in self?.runStale() }
    }

    public func stop() {
        stopped = true
        sock?.close()
        DispatchQueue.main.async {
            self.snapshot = nil
            self.roster = TestLinkRoster()
            self.lastRosterKey = ""
            self.rosterTick &+= 1
        }
    }

    private func run() {
        do {
            let socket = try UDPSocket(listenPort: TestLink.port)
            sock = socket
            while !stopped {
                guard let (data, _) = socket.receive() else { continue }
                guard var frame = try? JSONDecoder().decode(TestLinkSnapshot.self, from: data) else { continue }
                if frame.decks.count > lastPeaks.count {
                    lastPeaks.append(contentsOf: Array(repeating: [UInt8](), count: frame.decks.count - lastPeaks.count))
                }
                if frame.decks.count > lastBPM.count {
                    lastBPM.append(contentsOf: Array(repeating: 0.0, count: frame.decks.count - lastBPM.count))
                    lastBPMTitle.append(contentsOf: Array(repeating: "", count: frame.decks.count - lastBPMTitle.count))
                }
                for i in frame.decks.indices {
                    if frame.decks[i].peaks.isEmpty,
                       frame.decks[i].loaded,
                       i < lastPeaks.count,
                       !lastPeaks[i].isEmpty {
                        frame.decks[i].peaks = lastPeaks[i]
                    } else if !frame.decks[i].peaks.isEmpty {
                        lastPeaks[i] = frame.decks[i].peaks
                    } else if !frame.decks[i].loaded, i < lastPeaks.count {
                        lastPeaks[i] = []
                    }
                    frame.decks[i].title = TrackNaming.cleanTitle(frame.decks[i].title)
                    let title = frame.decks[i].title
                    if frame.decks[i].bpm > 0 {
                        lastBPM[i] = frame.decks[i].bpm
                        lastBPMTitle[i] = title
                    } else if frame.decks[i].loaded,
                              lastBPM[i] > 0,
                              lastBPMTitle[i] == title,
                              !title.isEmpty {
                        // Race: push con pista pero BPM aún 0. Conservar el último bueno.
                        frame.decks[i].bpm = lastBPM[i]
                    } else if !frame.decks[i].loaded {
                        lastBPM[i] = 0
                        lastBPMTitle[i] = ""
                    }
                }
                lastHeard = Date()
                let rosterKey = "\(frame.denonOn)|\(frame.pioneerOn)|" + frame.decks.map {
                    "\($0.loaded ? 1 : 0):\($0.title)"
                }.joined(separator: ",")
                let loadedLayers = frame.decks.map(\.loaded)
                DispatchQueue.main.async {
                    self.snapshot = frame
                    if rosterKey != self.lastRosterKey {
                        self.lastRosterKey = rosterKey
                        self.roster = TestLinkRoster(
                            denonOn: frame.denonOn,
                            pioneerOn: frame.pioneerOn,
                            loadedLayers: loadedLayers.isEmpty ? [false, false] : loadedLayers
                        )
                        self.rosterTick &+= 1
                    }
                }
            }
            socket.close()
        } catch {
            // Puerto ocupado: la app sigue; TEST no superpondrá.
        }
    }

    private func runStale() {
        while !stopped {
            Thread.sleep(forTimeInterval: 0.4)
            if Date().timeIntervalSince(lastHeard) > 2.0 {
                DispatchQueue.main.async {
                    if self.snapshot != nil {
                        self.snapshot = nil
                        self.roster = TestLinkRoster()
                        self.lastRosterKey = ""
                        self.rosterTick &+= 1
                    }
                }
            }
        }
    }
}
