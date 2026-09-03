// SoftwareDJManager.swift
// Fuentes de software en el mismo Mac: VirtualDJ (HTTP Network Control) y
// Serato DJ Pro (OSC-over-TCP _SeratoIOSRemote). Nada inventado: si el
// programa no habla, la fila no aparece.

import Foundation
import Combine
import Network
import CommonCrypto
#if canImport(Darwin)
import Darwin
#endif

public enum SoftwareDJKind: String, Sendable {
    case serato
    case virtualdj
}

public final class SoftwareDeck: ObservableObject, Identifiable {
    public let id: String
    public let kind: SoftwareDJKind
    public let deckIndex: Int

    @Published public var title: String = ""
    @Published public var artist: String = ""
    @Published public var bpm: Double = 0
    @Published public var playing: Bool = false
    @Published public var loaded: Bool = false
    @Published public var position: Double = 0
    @Published public var lastSeen: Date = .distantPast

    public init(kind: SoftwareDJKind, deckIndex: Int) {
        self.kind = kind
        self.deckIndex = deckIndex
        self.id = "\(kind.rawValue)-\(deckIndex)"
    }

    public var shortName: String {
        switch kind {
        case .serato: return "SERATO \(deckIndex + 1)"
        case .virtualdj: return "VDJ \(deckIndex + 1)"
        }
    }
}

public final class SoftwareDJManager: ObservableObject {
    @Published public private(set) var decks: [SoftwareDeck] = []
    @Published public var seratoStatus: String = "sin Serato"
    @Published public var vdjStatus: String = "sin VirtualDJ"
    @Published public var rosterTick: UInt64 = 0

    private let vdj = VirtualDJPoller()
    private let serato = SeratoRemoteServer()
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        vdj.onUpdate = { [weak self] decks, status in
            self?.merge(kind: .virtualdj, incoming: decks, status: status)
        }
        serato.onUpdate = { [weak self] decks, status in
            self?.merge(kind: .serato, incoming: decks, status: status)
        }
        vdj.start()
        serato.start()
    }

    public func stop() {
        started = false
        vdj.stop()
        serato.stop()
    }

    public var liveDecks: [SoftwareDeck] {
        decks.filter { $0.loaded && (!$0.title.isEmpty || $0.playing) }
    }

    public var seratoLiveCount: Int { liveDecks.filter { $0.kind == .serato }.count }
    public var vdjLiveCount: Int { liveDecks.filter { $0.kind == .virtualdj }.count }

    private func merge(kind: SoftwareDJKind, incoming: [SoftwareDeckSnapshot], status: String) {
        DispatchQueue.main.async {
            switch kind {
            case .serato: self.seratoStatus = status
            case .virtualdj: self.vdjStatus = status
            }
            let keep = self.decks.filter { $0.kind == kind }
            var next = self.decks.filter { $0.kind != kind }
            for snap in incoming {
                let id = "\(kind.rawValue)-\(snap.index)"
                let deck = keep.first(where: { $0.id == id }) ?? SoftwareDeck(kind: kind, deckIndex: snap.index)
                deck.title = snap.title
                deck.artist = snap.artist
                deck.bpm = snap.bpm
                deck.playing = snap.playing
                deck.loaded = snap.loaded
                deck.position = snap.position
                deck.lastSeen = Date()
                next.append(deck)
            }
            next.sort { a, b in
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                return a.deckIndex < b.deckIndex
            }
            let sig = next.map { "\($0.id):\($0.loaded ? 1 : 0):\($0.title)" }.joined()
            let prev = self.decks.map { "\($0.id):\($0.loaded ? 1 : 0):\($0.title)" }.joined()
            self.decks = next
            if sig != prev { self.rosterTick &+= 1 }
        }
    }
}

struct SoftwareDeckSnapshot {
    var index: Int
    var title: String
    var artist: String
    var bpm: Double
    var playing: Bool
    var loaded: Bool
    var position: Double
}

// MARK: - VirtualDJ Network Control (HTTP localhost)

private final class VirtualDJPoller {
    var onUpdate: (([SoftwareDeckSnapshot], String) -> Void)?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.entikrecords.stageconnect.vdj")
    private var port: Int?
    private let ports = [8080, 80, 8090, 8000, 9080]
    private var probing = false

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.4, repeating: 0.55)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        port = nil
    }

    private func tick() {
        if port == nil {
            guard !probing else { return }
            probing = true
            probe { [weak self] found in
                guard let self else { return }
                self.probing = false
                self.port = found
                if found == nil {
                    self.onUpdate?([], "VirtualDJ: no hay Network Control en localhost (8080/80/8090)")
                }
            }
            return
        }
        guard let port else { return }
        fetchDecks(port: port)
    }

    private func probe(done: @escaping (Int?) -> Void) {
        func tryIndex(_ i: Int) {
            if i >= ports.count { done(nil); return }
            let p = ports[i]
            query(port: p, script: "get_vdj_version") { body in
                if body != nil { done(p) } else { tryIndex(i + 1) }
            }
        }
        tryIndex(0)
    }

    private func fetchDecks(port: Int) {
        let group = DispatchGroup()
        var snaps: [SoftwareDeckSnapshot] = []
        let lock = NSLock()
        var anyOK = false
        for i in 1...4 {
            group.enter()
            let script = "get_text '`deck \(i) get_loaded_song \"title\"`\u{1f}`deck \(i) get_loaded_song \"artist\"`\u{1f}`deck \(i) get_bpm`\u{1f}`deck \(i) play`\u{1f}`deck \(i) get_time`'"
            query(port: port, script: script) { body in
                defer { group.leave() }
                guard let body else { return }
                anyOK = true
                let parts = body.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                let title = TrackNaming.cleanTitle(Self.clean(parts[safe: 0] ?? ""))
                let artist = Self.clean(parts[safe: 1] ?? "")
                let bpm = Double(Self.clean(parts[safe: 2] ?? "").replacingOccurrences(of: ",", with: ".")) ?? 0
                let playing = Self.truthy(parts[safe: 3] ?? "")
                let pos = Double(Self.clean(parts[safe: 4] ?? "").replacingOccurrences(of: ",", with: ".")) ?? 0
                let loaded = !title.isEmpty || playing
                if loaded {
                    lock.lock()
                    snaps.append(SoftwareDeckSnapshot(
                        index: i - 1, title: title, artist: artist,
                        bpm: bpm, playing: playing, loaded: loaded, position: pos
                    ))
                    lock.unlock()
                }
            }
        }
        group.notify(queue: queue) { [weak self] in
            if !anyOK {
                self?.port = nil
                self?.onUpdate?([], "VirtualDJ: Network Control no responde")
                return
            }
            self?.onUpdate?(snaps, snaps.isEmpty
                ? "VirtualDJ en :\(port) — sin pista"
                : "VirtualDJ :\(port) · \(snaps.count) deck\(snaps.count == 1 ? "" : "s")")
        }
    }

    private func query(port: Int, script: String, done: @escaping (String?) -> Void) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+")
        guard let enc = script.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "http://127.0.0.1:\(port)/query?script=\(enc)")
        else { done(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.7
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data, let text = String(data: data, encoding: .utf8)
            else { done(nil); return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased().contains("cannot get") || t.lowercased().contains("not found") {
                done(nil)
                return
            }
            guard Self.looksLikeVDJBody(t) else {
                done(nil)
                return
            }
            done(t)
        }.resume()
    }

    private static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
    }

    private static func truthy(_ raw: String) -> Bool {
        let s = clean(raw).lowercased()
        return s == "1" || s == "true" || s == "on" || s == "yes" || s == "play"
    }

    /// El web de STAGE CONNECT (:8080) devolvía HTML 200 a /query y Auto
    /// pasaba a Dual/VDJ con filas fantasma. VDJ responde texto corto.
    private static func looksLikeVDJBody(_ text: String) -> Bool {
        if text.isEmpty { return false }
        let lower = text.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") { return false }
        if lower.contains("\"decks\"") && (lower.contains("\"tc\"") || lower.contains("\"isplaying\"")) {
            return false
        }
        return text.count <= 400
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Serato Remote (OSC-over-TCP, _SeratoIOSRemote._tcp)

/// Servidor remoto: Serato se conecta a nosotros. Handshake documentado en
/// chrisle/serato-connect (secrets en el binario de Serato, interop local).
private final class SeratoRemoteServer: NSObject, NetServiceDelegate {
    var onUpdate: (([SoftwareDeckSnapshot], String) -> Void)?

    private let queue = DispatchQueue(label: "com.entikrecords.stageconnect.serato")
    private var listener: NWListener?
    private var service: NetService?
    private var connections: [ObjectIdentifier: SeratoConnection] = [:]
    private var decks: [Int: SoftwareDeckSnapshot] = [:]
    private var lastUIPush = Date.distantPast
    private let peerName = "STAGE CONNECT"
    private let peerUUID = UUID().uuidString
    private var running = false

    private static let sentinel = Data([
        0x4c, 0xaa, 0xc2, 0xae, 0x35, 0xb1, 0xc4, 0x76,
        0xdb, 0x5a, 0x64, 0x44, 0x03, 0xbd, 0x41, 0x70
    ])
    private static let secretA = Data([
        0xd2, 0x5d, 0xb2, 0x61, 0xa4, 0x41, 0x1b, 0xc1,
        0xf3, 0x78, 0x8f, 0x57, 0x72, 0x3b, 0x89, 0x77,
        0xc5, 0x41, 0xa4, 0xb6, 0x19, 0xb9, 0x4a, 0x9a,
        0x8b, 0x45, 0xc4, 0x6f, 0x85, 0x11, 0xc2, 0xf8
    ])

    func start() {
        guard !running else { return }
        running = true
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = listener.port {
                    self.publish(port: Int(port.rawValue))
                    self.onUpdate?([], "Serato: anunciado _SeratoIOSRemote :\(port.rawValue) — abre Serato DJ Pro")
                }
                if case .failed = state {
                    self.onUpdate?([], "Serato: no se pudo abrir el listener OSC")
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
        } catch {
            onUpdate?([], "Serato: listener TCP falló")
        }
    }

    func stop() {
        running = false
        listener?.cancel()
        listener = nil
        service?.stop()
        service = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        decks.removeAll()
    }

    private func publish(port: Int) {
        let host = ProcessInfo.processInfo.hostName
        let svc = NetService(domain: "local.", type: "_SeratoIOSRemote._tcp.",
                             name: "\(peerName) @ \(host)", port: Int32(port))
        svc.delegate = self
        svc.publish()
        service = svc
    }

    private func accept(_ nw: NWConnection) {
        let box = SeratoConnection(nw: nw, sentinel: Self.sentinel)
        let id = ObjectIdentifier(box)
        connections[id] = box
        box.onFrame = { [weak self, weak box] packet in
            guard let self, let box else { return }
            self.handle(packet, from: box)
        }
        box.onClose = { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        box.start(queue: queue)
    }

    private func handle(_ packet: Data, from conn: SeratoConnection) {
        let messages = OSCCodec.decodePacket(packet)
        for msg in messages {
            switch msg.path {
            case "/Ping":
                conn.send(OSCCodec.message("/Ping", tags: ",", args: []))
            case "/StreamMgmt/Authorize/Request":
                if case .blob(let nonce)? = msg.args.first {
                    let digest = Self.md5(nonce + Self.secretA)
                    conn.send(OSCCodec.message(
                        "/StreamMgmt/Authorize/Response",
                        tags: ",ssb",
                        args: [.string(peerName), .string(peerUUID), .blob(digest)]
                    ))
                }
            case "/StreamMgmt/Pairing/Pair":
                conn.send(OSCCodec.message(
                    "/StreamMgmt/Pairing/Pair",
                    tags: ",ssi",
                    args: [.string(peerName), .string(peerUUID), .int(1)]
                ))
                for topic in [
                    "/Register/Status/Deck/Song/Title",
                    "/Register/Status/Deck/Song/Artist",
                    "/Register/Status/Deck/Song/Valid",
                    "/Register/Status/Deck/Playhead"
                ] {
                    conn.send(OSCCodec.message(topic, tags: ",", args: []))
                }
            default:
                applyStatus(msg)
            }
        }
    }

    private func applyStatus(_ msg: OSCMessage) {
        let path = msg.path
        guard path.hasPrefix("/Status/Deck/") else { return }
        guard let deck = msg.args.first.flatMap({ $0.intValue }) else { return }
        var snap = decks[deck] ?? SoftwareDeckSnapshot(
            index: deck, title: "", artist: "", bpm: 0, playing: false, loaded: false, position: 0
        )
        switch path {
        case "/Status/Deck/Song/Title":
            if let s = msg.args[safe: 1]?.stringValue {
                snap.title = TrackNaming.cleanTitle(s)
                snap.loaded = !snap.title.isEmpty || snap.playing
            }
        case "/Status/Deck/Song/Artist":
            if let s = msg.args[safe: 1]?.stringValue { snap.artist = s }
        case "/Status/Deck/Song/Valid":
            if let v = msg.args[safe: 1]?.floatValue { snap.loaded = v > 0.5 }
        case "/Status/Deck/Playhead":
            if let pos = msg.args[safe: 1]?.floatValue { snap.position = Double(pos) }
            if let rate = msg.args[safe: 2]?.floatValue { snap.playing = rate > 0.02 }
            if let bpm = msg.args[safe: 3]?.floatValue { snap.bpm = Double(bpm) }
            if snap.playing { snap.loaded = true }
        default:
            break
        }
        let titleChanged = decks[deck]?.title != snap.title
        decks[deck] = snap
        let now = Date()
        if !titleChanged, now.timeIntervalSince(lastUIPush) < 0.12 { return }
        lastUIPush = now
        let list = decks.values.sorted { $0.index < $1.index }.filter { $0.loaded }
        let n = list.count
        onUpdate?(list, n == 0 ? "Serato conectado — sin pista" : "Serato · \(n) deck\(n == 1 ? "" : "s")")
    }

    private static func md5(_ data: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &out)
        }
        return Data(out)
    }
}

private final class SeratoConnection {
    let nw: NWConnection
    let sentinel: Data
    var onFrame: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private var buf = Data()

    init(nw: NWConnection, sentinel: Data) {
        self.nw = nw
        self.sentinel = sentinel
    }

    func start(queue: DispatchQueue) {
        nw.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state { self?.onClose?() }
        }
        nw.start(queue: queue)
        receive()
    }

    func cancel() {
        nw.cancel()
    }

    func send(_ packet: Data) {
        var frame = packet
        frame.append(sentinel)
        nw.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buf.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.cancel()
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while let range = buf.range(of: sentinel) {
            let packet = buf.subdata(in: buf.startIndex..<range.lowerBound)
            buf.removeSubrange(buf.startIndex..<range.upperBound)
            if !packet.isEmpty { onFrame?(packet) }
        }
        if buf.count > 2_000_000 { buf.removeAll(keepingCapacity: true) }
    }
}

// MARK: - OSC mínimo (1.1, alineado a 4)

enum OSCArg {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)

    var intValue: Int? {
        if case .int(let v) = self { return Int(v) }
        return nil
    }
    var floatValue: Float? {
        switch self {
        case .float(let v): return v
        case .int(let v): return Float(v)
        default: return nil
        }
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

struct OSCMessage {
    var path: String
    var args: [OSCArg]
}

enum OSCCodec {
    static func message(_ path: String, tags: String, args: [OSCArg]) -> Data {
        var d = pad(path)
        d.append(pad(tags.hasPrefix(",") ? tags : "," + tags))
        for a in args {
            switch a {
            case .int(let v):
                var be = v.bigEndian
                d.append(Data(bytes: &be, count: 4))
            case .float(let v):
                var be = v.bitPattern.bigEndian
                d.append(Data(bytes: &be, count: 4))
            case .string(let s):
                d.append(pad(s))
            case .blob(let b):
                var n = Int32(b.count).bigEndian
                d.append(Data(bytes: &n, count: 4))
                d.append(b)
                let rem = (4 - (b.count % 4)) % 4
                if rem > 0 { d.append(Data(repeating: 0, count: rem)) }
            }
        }
        return d
    }

    static func decodePacket(_ data: Data) -> [OSCMessage] {
        if data.starts(with: Array("#bundle".utf8)) {
            return decodeBundle(data)
        }
        if let m = decodeMessage(data) { return [m] }
        return []
    }

    private static func decodeBundle(_ data: Data) -> [OSCMessage] {
        var i = 8 + 8
        var out: [OSCMessage] = []
        while i + 4 <= data.count {
            let size = int32(data, i)
            i += 4
            guard size > 0, i + Int(size) <= data.count else { break }
            let slice = data.subdata(in: i..<(i + Int(size)))
            out.append(contentsOf: decodePacket(slice))
            i += Int(size)
        }
        return out
    }

    private static func decodeMessage(_ data: Data) -> OSCMessage? {
        guard let path = cString(data, 0) else { return nil }
        var i = aligned(path.byteEnd)
        var tags = ","
        if i < data.count, data[i] == 0x2c, let tagStr = cString(data, i) {
            tags = tagStr.value
            i = aligned(tagStr.byteEnd)
        }
        var args: [OSCArg] = []
        for ch in tags.dropFirst() {
            switch ch {
            case "i":
                guard i + 4 <= data.count else { return OSCMessage(path: path.value, args: args) }
                args.append(.int(int32(data, i)))
                i += 4
            case "f":
                guard i + 4 <= data.count else { return OSCMessage(path: path.value, args: args) }
                args.append(.float(Float(bitPattern: UInt32(bitPattern: int32(data, i)))))
                i += 4
            case "s":
                guard let s = cString(data, i) else { return OSCMessage(path: path.value, args: args) }
                args.append(.string(s.value))
                i = aligned(s.byteEnd)
            case "b":
                guard i + 4 <= data.count else { return OSCMessage(path: path.value, args: args) }
                let n = Int(int32(data, i))
                i += 4
                guard n >= 0, i + n <= data.count else { return OSCMessage(path: path.value, args: args) }
                args.append(.blob(data.subdata(in: i..<(i + n))))
                i = aligned(i + n)
            default:
                break
            }
        }
        return OSCMessage(path: path.value, args: args)
    }

    private static func pad(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0)
        let rem = (4 - (d.count % 4)) % 4
        if rem > 0 { d.append(Data(repeating: 0, count: rem)) }
        return d
    }

    private static func aligned(_ i: Int) -> Int { (i + 3) & ~3 }

    private static func int32(_ data: Data, _ i: Int) -> Int32 {
        let b = [UInt8](data[i..<(i + 4)])
        return Int32(b[0]) << 24 | Int32(b[1]) << 16 | Int32(b[2]) << 8 | Int32(b[3])
    }

    private static func cString(_ data: Data, _ start: Int) -> (value: String, byteEnd: Int)? {
        guard start < data.count else { return nil }
        var end = start
        while end < data.count, data[end] != 0 { end += 1 }
        let s = String(data: data.subdata(in: start..<end), encoding: .utf8) ?? ""
        return (s, end + 1)
    }
}
