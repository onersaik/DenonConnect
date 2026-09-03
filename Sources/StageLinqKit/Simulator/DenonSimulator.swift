// DenonSimulator.swift
// Simula un Denon SC6000 en la red: se anuncia por StageLinq, acepta la
// conexión principal, anuncia los servicios StateMap y BeatInfo y emite
// estado y beats de dos decks con una pista ficticia sonando.
//
// Sirve para comprobar que la app recibe, interpreta y pinta los datos sin
// necesidad de tener el equipo delante.
//
// IMPORTANTE: el simulador está construido con la misma interpretación del
// protocolo que el cliente. Que los dos se entiendan demuestra que la app
// funciona de punta a punta (framing, cadenas, JSON, refresco de interfaz),
// pero NO demuestra que esa interpretación coincida con un SC6000 real. Eso
// solo lo confirma el equipo físico.

import Foundation

// MARK: - Estado externo inyectable desde el simulador UI

public struct SimDeckState: Sendable {
    public var title: String
    public var artist: String
    public var bpm: Double
    public var isPlaying: Bool
    public var positionSeconds: Double   // posición actual en segundos
    public var duration: Double          // duración total en segundos
    public var isMaster: Bool
    public var key: String
    public var pitchPercent: Double
    public var isSync: Bool

    public init(title: String = "", artist: String = "", bpm: Double = 0,
                isPlaying: Bool = false, positionSeconds: Double = 0,
                duration: Double = 0, isMaster: Bool = false, key: String = "",
                pitchPercent: Double = 0, isSync: Bool = false) {
        self.title = title; self.artist = artist; self.bpm = bpm
        self.isPlaying = isPlaying; self.positionSeconds = positionSeconds
        self.duration = duration; self.isMaster = isMaster; self.key = key
        self.pitchPercent = pitchPercent; self.isSync = isSync
    }
}

public final class DenonSimulator {
    public static let mainPort: UInt16 = 51338
    public static let stateMapPort: UInt16 = 51339
    public static let beatInfoPort: UInt16 = 51340

    /// Token propio, distinto del que usa el cliente, para que la app no
    /// confunda este anuncio con el suyo. ContentView filtra el SIM por este
    /// token o por el nombre (SC6000-SIM), nunca un SC6000 real.
    public static let announcementToken: [UInt8] = [
        11, 22, 33, 44, 55, 66, 77, 88, 99, 110, 121, 132, 143, 154, 165, 176,
    ]
    private var token: [UInt8] { Self.announcementToken }


    /// Proveedor de estado externo. Si está configurado, snapshot() lo usa en lugar del
    /// reloj interno. El SimulatorController lo asigna para que los datos reales fluyan.
    public var stateProvider: (() -> [SimDeckState])?

    /// Si es true y no hay stateProvider, se emiten los decks internos.
    /// Por defecto false: sin proveedor no hay pista (la app principal no ve nada ficticio).
    public var standaloneMode: Bool = false

    private let deviceName: String
    private let log: (String) -> Void

    private let queue = DispatchQueue(label: "com.entikrecords.simulator.denon", qos: .userInitiated, attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "com.entikrecords.simulator.denon.state")
    private var stoppedFlag = false

    private var announceSocket: UDPSocket?
    private var mainListener: TCPListener?
    private var stateListener: TCPListener?
    private var beatListener: TCPListener?

    // Pista simulada por deck
    private struct SimDeck {
        var title: String
        var artist: String
        var key: String
        var genre: String
        var bpm: Double
        var lengthSeconds: Double
        var playing: Bool
        var beat: Double
        var isMaster: Bool
    }

    private var decks: [SimDeck] = [
        SimDeck(title: "", artist: "", key: "", genre: "", bpm: 128.0, lengthSeconds: 300, playing: false, beat: 0, isMaster: false),
        SimDeck(title: "", artist: "", key: "", genre: "", bpm: 128.0, lengthSeconds: 300, playing: false, beat: 0, isMaster: false),
    ]

    public init(deviceName: String = "SC6000-SIM", log: @escaping (String) -> Void = { _ in }) {
        self.deviceName = deviceName
        self.log = log
    }

    private var stopped: Bool { stateQueue.sync { stoppedFlag } }

    public func start() {
        stateQueue.sync { stoppedFlag = false }
        queue.async { [weak self] in self?.runAnnounce() }
        queue.async { [weak self] in self?.runMainListener() }
        queue.async { [weak self] in self?.runStateMapListener() }
        queue.async { [weak self] in self?.runBeatInfoListener() }
        queue.async { [weak self] in self?.runClock() }
        log("[Denon] Activo como «\(deviceName)»")
    }

    public func stop() {
        stateQueue.sync { stoppedFlag = true }
        if let sock = announceSocket {
            let packet = DiscoveryCodec.build(
                token: token,
                source: "JC11",
                action: StageLinq.actionLogout,
                name: deviceName,
                version: "1.6.0",
                port: DenonSimulator.mainPort
            )
            sock.send(packet, to: "255.255.255.255", port: StageLinq.listenPort)
        }
        announceSocket?.close()
        mainListener?.close()
        stateListener?.close()
        beatInfoListenerClose()
        log("[Denon] Detenido")
    }

    private func beatInfoListenerClose() {
        beatListener?.close()
    }

    // MARK: - Reloj: hace avanzar los beats de las pistas simuladas

    private func runClock() {
        let tick = 1.0 / 60.0
        while !stopped {
            // Cuando el stateProvider está activo, la posición viene de fuera
            if stateProvider == nil {
                stateQueue.sync {
                    for i in decks.indices where decks[i].playing {
                        decks[i].beat += (decks[i].bpm / 60.0) * tick
                        let totalBeats = decks[i].lengthSeconds * decks[i].bpm / 60.0
                        if decks[i].beat > totalBeats { decks[i].beat = 0 }
                    }
                }
                Thread.sleep(forTimeInterval: tick)
            } else {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    private static let unloadedDecks: [SimDeck] = [
        SimDeck(title: "", artist: "", key: "", genre: "", bpm: 0, lengthSeconds: 0, playing: false, beat: 0, isMaster: false),
        SimDeck(title: "", artist: "", key: "", genre: "", bpm: 0, lengthSeconds: 0, playing: false, beat: 0, isMaster: false),
    ]

    private func snapshot() -> [SimDeck] {
        if let provider = stateProvider {
            return provider().map { s in
                let loaded = !s.title.isEmpty || s.duration > 0
                let bpm = MusicalClock.bpm(s.bpm)
                let dur = s.duration > 0 ? s.duration : 0
                let beats = (loaded && dur > 0 && bpm > 0) ? s.positionSeconds * bpm / 60.0 : 0
                return SimDeck(
                    title: s.title,
                    artist: s.artist,
                    key: s.key,
                    genre: "",
                    bpm: bpm,
                    lengthSeconds: dur,
                    playing: loaded && s.isPlaying,
                    beat: beats,
                    isMaster: s.isMaster)
            }
        }
        if standaloneMode {
            return stateQueue.sync { decks }
        }
        return Self.unloadedDecks
    }

    // MARK: - Anuncio por UDP

    private func runAnnounce() {
        guard let sock = try? UDPSocket(listenPort: nil) else {
            log("[AVISO] Denon: no se pudo crear el socket de anuncio")
            return
        }
        announceSocket = sock

        let packet = DiscoveryCodec.build(
            token: token,
            source: "JC11",
            action: StageLinq.actionLogin,
            name: deviceName,
            version: "1.6.0",
            port: DenonSimulator.mainPort
        )

        while !stopped {
            sock.send(packet, to: "255.255.255.255", port: StageLinq.listenPort)
            Thread.sleep(forTimeInterval: 1.0)
        }
        sock.close()
    }

    // MARK: - Conexión principal: concede permiso y anuncia servicios

    private func runMainListener() {
        guard let listener = try? TCPListener(port: DenonSimulator.mainPort) else {
            log("[AVISO] Denon: puerto \(DenonSimulator.mainPort) ocupado")
            return
        }
        mainListener = listener

        while !stopped {
            guard let conn = listener.accept() else { continue }
            log("[Conexion] La app se ha conectado a la conexión principal")
            queue.async { [weak self] in self?.serveMain(conn) }
        }
        listener.close()
    }

    private func serveMain(_ conn: TCPConnection) {
        // 1) Permiso para pedir servicios.
        let permission = ByteWriter()
        permission.writeUInt32(StageLinq.MessageId.servicesRequest)
        permission.writeBytes(token)
        try? conn.send(permission.data)

        // 2) Anuncio de los servicios disponibles.
        announceService(conn, name: "StateMap", port: DenonSimulator.stateMapPort)
        announceService(conn, name: "BeatInfo", port: DenonSimulator.beatInfoPort)
        log("[Info] Servicios anunciados: StateMap y BeatInfo")

        // 3) Mantenemos la conexión viva leyendo lo que mande la app.
        while !stopped {
            do {
                _ = try conn.receive()
            } catch {
                break
            }
        }
        conn.close()
    }

    private func announceService(_ conn: TCPConnection, name: String, port: UInt16) {
        let w = ByteWriter()
        w.writeUInt32(StageLinq.MessageId.servicesAnnouncement)
        w.writeBytes(token)
        w.writeNetworkString(name)
        w.writeUInt16(port)
        try? conn.send(w.data)
    }

    // MARK: - Servicio StateMap

    private func runStateMapListener() {
        guard let listener = try? TCPListener(port: DenonSimulator.stateMapPort) else {
            log("[AVISO] Denon: puerto \(DenonSimulator.stateMapPort) ocupado")
            return
        }
        stateListener = listener

        while !stopped {
            guard let conn = listener.accept() else { continue }
            log("[Info] La app se ha suscrito a StateMap")
            queue.async { [weak self] in self?.serveStateMap(conn) }
        }
        listener.close()
    }

    private func serveStateMap(_ conn: TCPConnection) {
        // Timeout corto: el receive bloqueante de 5 s retrasaba Play/título
        // hasta el siguiente timeout del cliente.
        conn.setReadTimeout(milliseconds: 20)
        sendFullState(conn)

        var last = snapshot()
        var ticks = 0
        while !stopped {
            do {
                _ = try conn.receive()
            } catch {
                break
            }
            let current = snapshot()
            ticks += 1
            if ticks % 60 == 0 {
                sendFullState(conn)
            } else {
                sendStateDiff(conn, previous: last, current: current)
            }
            last = current
            Thread.sleep(forTimeInterval: 1.0 / 30.0)
        }
        conn.close()
    }

    private func sendStateDiff(_ conn: TCPConnection, previous: [SimDeck], current: [SimDeck]) {
        for (index, deck) in current.enumerated() {
            let n = index + 1
            let prev = index < previous.count ? previous[index] : nil
            if prev?.playing != deck.playing {
                sendState(conn, path: "/Engine/Deck\(n)/Play", json: boolJSON(deck.playing))
            }
            if prev?.title != deck.title {
                sendState(conn, path: "/Engine/Deck\(n)/Track/SongName", json: stringJSON(deck.title))
                sendState(conn, path: "/Engine/Deck\(n)/Track/SongLoaded", json: boolJSON(!deck.title.isEmpty))
            }
            if prev?.artist != deck.artist {
                sendState(conn, path: "/Engine/Deck\(n)/Track/ArtistName", json: stringJSON(deck.artist))
            }
            if prev.map({ abs($0.bpm - deck.bpm) > 0.001 }) ?? true {
                sendState(conn, path: "/Engine/Deck\(n)/CurrentBPM", json: numberJSON(deck.bpm))
            }
            if prev.map({ abs($0.lengthSeconds - deck.lengthSeconds) > 0.01 }) ?? true {
                sendState(conn, path: "/Engine/Deck\(n)/Track/TrackLength", json: numberJSON(deck.lengthSeconds))
            }
            if prev?.isMaster != deck.isMaster, n <= 2 {
                sendState(conn, path: "/Client/Deck\(n)/DeckIsMaster", json: boolJSON(deck.isMaster))
            }
        }
        let masterTempo = current.first(where: { $0.isMaster })?.bpm ?? 0
        let prevMaster = previous.first(where: { $0.isMaster })?.bpm ?? 0
        if abs(masterTempo - prevMaster) > 0.001 {
            sendState(conn, path: "/Engine/Master/MasterTempo", json: numberJSON(masterTempo))
        }
    }

    private func sendFullState(_ conn: TCPConnection) {
        let current = snapshot()
        var masterTempo = 0.0

        for (index, deck) in current.enumerated() {
            let n = index + 1
            if deck.isMaster { masterTempo = deck.bpm }

            let loaded = !deck.title.isEmpty || deck.lengthSeconds > 0
            sendState(conn, path: "/Engine/Deck\(n)/Track/SongLoaded", json: boolJSON(loaded))
            sendState(conn, path: "/Engine/Deck\(n)/Track/SongName", json: stringJSON(deck.title))
            sendState(conn, path: "/Engine/Deck\(n)/Track/ArtistName", json: stringJSON(deck.artist))
            sendState(conn, path: "/Engine/Deck\(n)/Track/CurrentKey", json: stringJSON(deck.key))
            sendState(conn, path: "/Engine/Deck\(n)/Track/Genre", json: stringJSON(deck.genre))
            sendState(conn, path: "/Engine/Deck\(n)/Track/TrackLength", json: numberJSON(deck.lengthSeconds))
            sendState(conn, path: "/Engine/Deck\(n)/Track/KeyLock", json: boolJSON(loaded))
            sendState(conn, path: "/Engine/Deck\(n)/Track/LoopEnableState", json: boolJSON(false))
            sendState(conn, path: "/Engine/Deck\(n)/CurrentBPM", json: numberJSON(deck.bpm))
            sendState(conn, path: "/Engine/Deck\(n)/ExternalMixerVolume", json: numberJSON(loaded ? (n == 1 ? 0.85 : 0.6) : 0))
            sendState(conn, path: "/Engine/Deck\(n)/Play", json: boolJSON(deck.playing))
            if n <= 2 {
                sendState(conn, path: "/Client/Deck\(n)/DeckIsMaster", json: boolJSON(deck.isMaster))
            }
        }

        sendState(conn, path: "/Engine/Master/MasterTempo", json: numberJSON(masterTempo))
        sendState(conn, path: "/Engine/DeckCount", json: numberJSON(Double(current.count)))
    }

    private func sendState(_ conn: TCPConnection, path: String, json: String) {
        let payload = ByteWriter()
        payload.writeFixedString(StageLinq.StateMapMarker.magic)
        payload.writeUInt32(StageLinq.StateMapMarker.typeJSON)
        payload.writeNetworkString(path)
        payload.writeNetworkString(json)

        let framed = ByteWriter()
        framed.writeUInt32(UInt32(payload.data.count))
        framed.writeData(payload.data)
        try? conn.send(framed.data)
    }

    private func boolJSON(_ value: Bool) -> String { "{\"state\":\(value ? "true" : "false")}" }
    private func numberJSON(_ value: Double) -> String { "{\"value\":\(value)}" }
    private func stringJSON(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"string\":\"\(escaped)\",\"type\":8}"
    }

    // MARK: - Servicio BeatInfo

    private func runBeatInfoListener() {
        guard let listener = try? TCPListener(port: DenonSimulator.beatInfoPort) else {
            log("[AVISO] Denon: puerto \(DenonSimulator.beatInfoPort) ocupado")
            return
        }
        beatListener = listener

        while !stopped {
            guard let conn = listener.accept() else { continue }
            log("[Info] La app se ha suscrito a BeatInfo")
            queue.async { [weak self] in self?.serveBeatInfo(conn) }
        }
        listener.close()
    }

    private func serveBeatInfo(_ conn: TCPConnection) {
        var clock: UInt64 = 0
        while !stopped {
            let current = snapshot()
            let payload = ByteWriter()
            payload.writeUInt32(0)
            payload.writeUInt64(clock)
            payload.writeUInt32(UInt32(current.count))
            for deck in current {
                let clock = MusicalClock.bpm(deck.bpm)
                let totalBeats = (clock > 0 && deck.lengthSeconds > 0) ? deck.lengthSeconds * clock / 60.0 : 0
                payload.writeFloat64(deck.beat)
                payload.writeFloat64(totalBeats)
                payload.writeFloat64(clock)
            }
            for _ in current {
                payload.writeFloat64(0)
            }

            let framed = ByteWriter()
            framed.writeUInt32(UInt32(payload.data.count))
            framed.writeData(payload.data)
            do {
                try conn.send(framed.data)
            } catch {
                break
            }

            clock &+= 1
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
        }
        conn.close()
    }
}
