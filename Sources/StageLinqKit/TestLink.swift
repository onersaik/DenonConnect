// TestLink.swift
// Canal local UDP 127.0.0.1:51341 entre STAGE CONNECT TEST y STAGE CONNECT.
// StageLinq no lleva picos de waveform. Pioneer a veces expone preview por dbserver;
// si no hay picos, la UI pinta envolvente plana (no un senoidal inventado).
// TEST publica título limpio, BPM, posición y picos RMS; la app principal
// los superpone en las filas Denon/Pioneer de este Mac.

import Foundation
import Combine

public enum TrackNaming {
    /// Limpia títulos de TEST, copias temporales y basura típica de filenames DJ.
    /// No es un editor de regex: reglas fijas y conservadoras.
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
        let lower = s.lowercased()
        for ext in [".mp3", ".m4a", ".mp4", ".aac", ".aiff", ".aif", ".wav", ".flac", ".ogg", ".wma"] {
            if lower.hasSuffix(ext) {
                s = String(s.dropLast(ext.count))
                break
            }
        }
        s = s.replacingOccurrences(
            of: #"\[(?:https?://)?(?:www\.)?[^\]\s]+\.[a-z]{2,}\]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: #"\((?:https?://)?(?:www\.)?[^)\s]+\.[a-z]{2,}\)"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: #"\s*[-–—_]?\s*\d{2,3}\s*k?bps\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"^\d{2}[\s.\-_]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Columnas objetivo del waveform RGB (TEST). UDP localhost aguanta ~64 KB.
    public static let waveformColumns = 12000
    /// Si el JSON no cabe, se baja por max-in-bin; nunca a 300 picos.
    public static let minWaveformColumns = 2400
    public static let udpSafeBytes = 62000

    public var title: String
    public var artist: String
    public var bpm: Double
    public var playing: Bool
    public var position: Double
    public var duration: Double
    /// Amplitud overall (legacy). STAGE CONNECT viejo ignora `bands`.
    public var peaks: [UInt8]
    /// Graves / medios / agudos, misma longitud. Vacío = solo `peaks`.
    public var peaksLow: [UInt8]
    public var peaksMid: [UInt8]
    public var peaksHigh: [UInt8]
    public var isMaster: Bool
    public var key: String
    public var genre: String
    public var album: String
    public var comment: String
    /// JPEG/PNG extraído del archivo en TEST (ruta local). Vacío = sin portada de archivo.
    public var artworkPath: String
    /// Miniatura JPEG base64 acotada. STAGE CONNECT la pinta si la ruta no se lee.
    public static let maxArtworkJPEGChars = 4000
    public var artworkJPEG: String
    /// Cues en segundos (pads Q1… del simulador). Vacío = sin cues.
    public var cues: [Double]
    /// Loop in/out en segundos. -1 = sin loop.
    public var loopIn: Double
    public var loopOut: Double
    /// Pitch ±% respecto al BPM de la pista. 0 = sin sliders.
    public var pitch: Double
    /// SYNC encendido en el reproductor (TEST / CDJ).
    public var isSync: Bool

    enum CodingKeys: String, CodingKey {
        case title, artist, bpm, playing, position, duration, peaks, isMaster, key, genre, album, comment
        case bands, artworkPath, artworkJPEG, cues, loopIn, loopOut, pitch, isSync
    }

    public init(title: String = "", artist: String = "", bpm: Double = 0,
                playing: Bool = false, position: Double = 0, duration: Double = 0,
                peaks: [UInt8] = [], isMaster: Bool = false, key: String = "",
                genre: String = "", album: String = "", comment: String = "",
                peaksLow: [UInt8] = [], peaksMid: [UInt8] = [], peaksHigh: [UInt8] = [],
                artworkPath: String = "", artworkJPEG: String = "",
                cues: [Double] = [], loopIn: Double = -1, loopOut: Double = -1,
                pitch: Double = 0, isSync: Bool = false) {
        self.title = TrackNaming.cleanTitle(title)
        self.artist = artist
        self.bpm = bpm
        self.playing = playing
        self.position = position
        self.duration = duration
        self.peaks = peaks
        self.peaksLow = peaksLow
        self.peaksMid = peaksMid
        self.peaksHigh = peaksHigh
        self.isMaster = isMaster
        self.key = key
        self.genre = genre
        self.album = album
        self.comment = comment
        self.artworkPath = artworkPath
        self.artworkJPEG = artworkJPEG
        self.cues = cues
        self.loopIn = loopIn
        self.loopOut = loopOut
        self.pitch = pitch
        self.isSync = isSync
        reconcileAmplitude()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = TrackNaming.cleanTitle(try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 0
        playing = try c.decodeIfPresent(Bool.self, forKey: .playing) ?? false
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        peaks = try c.decodeIfPresent([UInt8].self, forKey: .peaks) ?? []
        isMaster = try c.decodeIfPresent(Bool.self, forKey: .isMaster) ?? false
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        artworkPath = try c.decodeIfPresent(String.self, forKey: .artworkPath) ?? ""
        artworkJPEG = try c.decodeIfPresent(String.self, forKey: .artworkJPEG) ?? ""
        cues = try c.decodeIfPresent([Double].self, forKey: .cues) ?? []
        loopIn = try c.decodeIfPresent(Double.self, forKey: .loopIn) ?? -1
        loopOut = try c.decodeIfPresent(Double.self, forKey: .loopOut) ?? -1
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        isSync = try c.decodeIfPresent(Bool.self, forKey: .isSync) ?? false
        peaksLow = []
        peaksMid = []
        peaksHigh = []
        if let packed = try c.decodeIfPresent(String.self, forKey: .bands),
           let rgb = Self.unpackBands(packed) {
            peaksLow = rgb.low
            peaksMid = rgb.mid
            peaksHigh = rgb.high
        }
        reconcileAmplitude()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(playing, forKey: .playing)
        try c.encode(position, forKey: .position)
        try c.encode(duration, forKey: .duration)
        if hasRGB {
            // Peaks cortos para clientes viejos; la alta res va en `bands` (base64).
            try c.encode(Self.quantize(peaks.map { Float($0) / 255.0 }, count: 200), forKey: .peaks)
            try c.encode(Self.packBands(low: peaksLow, mid: peaksMid, high: peaksHigh), forKey: .bands)
        } else {
            try c.encode(peaks, forKey: .peaks)
        }
        try c.encode(isMaster, forKey: .isMaster)
        try c.encode(key, forKey: .key)
        try c.encode(genre, forKey: .genre)
        try c.encode(album, forKey: .album)
        try c.encode(comment, forKey: .comment)
        if !artworkPath.isEmpty {
            try c.encode(artworkPath, forKey: .artworkPath)
        }
        if !artworkJPEG.isEmpty {
            try c.encode(artworkJPEG, forKey: .artworkJPEG)
        }
        if !cues.isEmpty {
            try c.encode(cues, forKey: .cues)
        }
        if loopIn >= 0 { try c.encode(loopIn, forKey: .loopIn) }
        if loopOut >= 0 { try c.encode(loopOut, forKey: .loopOut) }
        if abs(pitch) > 0.001 { try c.encode(pitch, forKey: .pitch) }
        if isSync { try c.encode(isSync, forKey: .isSync) }
    }

    public var peaksFloat: [Float] {
        peaks.map { Float($0) / 255.0 }
    }

    public var hasRGB: Bool {
        let n = peaksLow.count
        return n > 1 && peaksMid.count == n && peaksHigh.count == n
    }

    public var progress: Double? {
        guard duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    public var cueFractions: [Double] {
        guard duration > 0 else { return [] }
        return cues.compactMap { t in
            guard t >= 0 else { return nil }
            return min(1, max(0, t / duration))
        }
    }

    public var loopInFraction: Double? {
        guard duration > 0, loopIn >= 0, loopOut >= 0, loopIn < loopOut else { return nil }
        return min(1, max(0, loopIn / duration))
    }

    public var loopOutFraction: Double? {
        guard duration > 0, loopIn >= 0, loopOut >= 0, loopIn < loopOut else { return nil }
        return min(1, max(0, loopOut / duration))
    }

    public var loaded: Bool { duration > 0 || !title.isEmpty }

    public mutating func stripWaveform() {
        peaks = []
        peaksLow = []
        peaksMid = []
        peaksHigh = []
    }

    /// Baja columnas RGB por max-in-bin si el datagrama se pasa de UDP.
    public mutating func compactBands(to count: Int) {
        guard hasRGB, peaksLow.count > count else { return }
        let n = max(Self.minWaveformColumns, count)
        peaksLow = Self.quantize(peaksLow.map { Float($0) / 255.0 }, count: n)
        peaksMid = Self.quantize(peaksMid.map { Float($0) / 255.0 }, count: n)
        peaksHigh = Self.quantize(peaksHigh.map { Float($0) / 255.0 }, count: n)
        reconcileAmplitude()
    }

    mutating func reconcileAmplitude() {
        guard hasRGB else { return }
        if peaks.count != peaksLow.count {
            peaks = (0..<peaksLow.count).map { i in
                max(peaksLow[i], peaksMid[i], peaksHigh[i])
            }
        }
    }

    public static func packBands(low: [UInt8], mid: [UInt8], high: [UInt8]) -> String {
        let n = min(low.count, mid.count, high.count)
        var bytes = [UInt8](repeating: 0, count: n * 3)
        if n > 0 {
            bytes.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                for i in 0..<n {
                    let o = i * 3
                    base[o] = low[i]
                    base[o + 1] = mid[i]
                    base[o + 2] = high[i]
                }
            }
        }
        return Data(bytes).base64EncodedString()
    }

    public static func unpackBands(_ s: String) -> (low: [UInt8], mid: [UInt8], high: [UInt8])? {
        guard let data = Data(base64Encoded: s), data.count >= 6, data.count % 3 == 0 else { return nil }
        let n = data.count / 3
        var low = [UInt8](repeating: 0, count: n)
        var mid = [UInt8](repeating: 0, count: n)
        var high = [UInt8](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<n {
                let o = i * 3
                low[i] = src[o]
                mid[i] = src[o + 1]
                high[i] = src[o + 2]
            }
        }
        return (low, mid, high)
    }

    public static func encodeU8(_ v: Float) -> UInt8 {
        UInt8(min(255, max(0, Int((v * 255).rounded()))))
    }

    /// Max-in-bin para no perder kicks al bajar resolución.
    public static func quantize(_ peaks: [Float], count: Int = waveformColumns) -> [UInt8] {
        guard !peaks.isEmpty else { return [] }
        let n = peaks.count
        if n == count {
            return peaks.map { encodeU8($0) }
        }
        let outCount = max(1, count)
        var out = [UInt8](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let s = Int((Double(i) / Double(outCount)) * Double(n))
            let e = max(s + 1, Int((Double(i + 1) / Double(outCount)) * Double(n)))
            var mx: Float = 0
            var j = s
            while j < e && j < n {
                mx = max(mx, peaks[j])
                j += 1
            }
            out[i] = encodeU8(mx)
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

    /// JSON listo para UDP: si no cabe, compacta bands; la miniatura JPEG no se tira.
    public func encodedForUDP() -> Data? {
        var frame = self
        var target = 0
        for d in frame.decks where d.hasRGB {
            target = max(target, d.peaksLow.count)
        }
        if target == 0 {
            return try? JSONEncoder().encode(frame)
        }
        for _ in 0..<10 {
            if let data = try? JSONEncoder().encode(frame), data.count <= TestLinkDeck.udpSafeBytes {
                return data
            }
            target = max(TestLinkDeck.minWaveformColumns, (target * 3) / 4)
            for i in frame.decks.indices {
                frame.decks[i].compactBands(to: target)
            }
            if target <= TestLinkDeck.minWaveformColumns {
                break
            }
        }
        if let data = try? JSONEncoder().encode(frame), data.count <= TestLinkDeck.udpSafeBytes {
            return data
        }
        // El datagrama no puede perder la portada: waveform ya está en caché del receptor.
        for i in frame.decks.indices {
            frame.decks[i].stripWaveform()
        }
        return try? JSONEncoder().encode(frame)
    }
}

/// Ruta compartida TEST → STAGE CONNECT. No /tmp: el .app a menudo no lo lee.
public enum StageConnectArtworkStore {
    public static func writableDirectory() -> URL {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let app = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(app.appendingPathComponent("STAGE CONNECT/art", isDirectory: true))
        }
        dirs.append(URL(fileURLWithPath: "/Users/Shared/STAGE CONNECT/art", isDirectory: true))
        for dir in dirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".w")
            if fm.createFile(atPath: probe.path, contents: Data([1])) {
                try? fm.removeItem(at: probe)
                return dir
            }
        }
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("stage-connect-art", isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
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
        let sig = snapshot.decks.map { "\($0.title)|\($0.peaks.count)|\($0.peaksLow.count)" }
        if sig == lastPeakSignature {
            frame.decks = frame.decks.map { d in
                var c = d
                c.stripWaveform()
                return c
            }
        } else {
            lastPeakSignature = sig
        }
        guard let data = frame.encodedForUDP() else { return }
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
    private var lastLow: [[UInt8]] = [[], []]
    private var lastMid: [[UInt8]] = [[], []]
    private var lastHigh: [[UInt8]] = [[], []]
    private var lastBPM: [Double] = [0, 0]
    private var lastBPMTitle: [String] = ["", ""]
    private var lastArtPath: [String] = ["", ""]
    private var lastArtJPEG: [String] = ["", ""]
    public private(set) var lastPacketAt = Date.distantPast
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
                    let extra = frame.decks.count - lastPeaks.count
                    lastPeaks.append(contentsOf: Array(repeating: [UInt8](), count: extra))
                    lastLow.append(contentsOf: Array(repeating: [UInt8](), count: extra))
                    lastMid.append(contentsOf: Array(repeating: [UInt8](), count: extra))
                    lastHigh.append(contentsOf: Array(repeating: [UInt8](), count: extra))
                    lastArtPath.append(contentsOf: Array(repeating: "", count: extra))
                    lastArtJPEG.append(contentsOf: Array(repeating: "", count: extra))
                }
                if frame.decks.count > lastBPM.count {
                    lastBPM.append(contentsOf: Array(repeating: 0.0, count: frame.decks.count - lastBPM.count))
                    lastBPMTitle.append(contentsOf: Array(repeating: "", count: frame.decks.count - lastBPMTitle.count))
                }
                for i in frame.decks.indices {
                    if frame.decks[i].loaded, i < lastPeaks.count {
                        if frame.decks[i].peaks.isEmpty, !lastPeaks[i].isEmpty {
                            frame.decks[i].peaks = lastPeaks[i]
                            frame.decks[i].peaksLow = lastLow[i]
                            frame.decks[i].peaksMid = lastMid[i]
                            frame.decks[i].peaksHigh = lastHigh[i]
                        } else if !frame.decks[i].peaks.isEmpty || frame.decks[i].hasRGB {
                            lastPeaks[i] = frame.decks[i].peaks
                            lastLow[i] = frame.decks[i].peaksLow
                            lastMid[i] = frame.decks[i].peaksMid
                            lastHigh[i] = frame.decks[i].peaksHigh
                        }
                    } else if !frame.decks[i].loaded, i < lastPeaks.count {
                        lastPeaks[i] = []
                        lastLow[i] = []
                        lastMid[i] = []
                        lastHigh[i] = []
                        if i < lastArtPath.count {
                            lastArtPath[i] = ""
                            lastArtJPEG[i] = ""
                        }
                    }
                    if frame.decks[i].loaded, i < lastArtPath.count {
                        if frame.decks[i].artworkPath.isEmpty, !lastArtPath[i].isEmpty {
                            frame.decks[i].artworkPath = lastArtPath[i]
                        } else if !frame.decks[i].artworkPath.isEmpty {
                            lastArtPath[i] = frame.decks[i].artworkPath
                        }
                        if frame.decks[i].artworkJPEG.isEmpty, !lastArtJPEG[i].isEmpty {
                            frame.decks[i].artworkJPEG = lastArtJPEG[i]
                        } else if !frame.decks[i].artworkJPEG.isEmpty {
                            lastArtJPEG[i] = frame.decks[i].artworkJPEG
                        }
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
                lastPacketAt = Date()
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
            if Date().timeIntervalSince(lastPacketAt) > 2.0 {
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
