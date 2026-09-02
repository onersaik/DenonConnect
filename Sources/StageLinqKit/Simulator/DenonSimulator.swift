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

public final class DenonSimulator {
    public static let mainPort: UInt16 = 51338
    public static let stateMapPort: UInt16 = 51339
    public static let beatInfoPort: UInt16 = 51340

    /// Token propio, distinto del que usa el cliente, para que la app no
    /// confunda este anuncio con el suyo.
    private let token: [UInt8] = [11, 22, 33, 44, 55, 66, 77, 88, 99, 110, 121, 132, 143, 154, 165, 176]

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
        SimDeck(title: "Midnight Protocol", artist: "Entik Records", key: "8A", genre: "Techno",
                bpm: 128.0, lengthSeconds: 312, playing: true, beat: 0, isMaster: true),
        SimDeck(title: "Warehouse Signal", artist: "DJ Saik", key: "9A", genre: "Tech House",
                bpm: 126.0, lengthSeconds: 268, playing: true, beat: 0, isMaster: false),
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
        log("🎛 Simulador Denon iniciado como «\(deviceName)»")
    }

    public func stop() {
        stateQueue.sync { stoppedFlag = true }
        announceSocket?.close()
        mainListener?.close()
        stateListener?.close()
        beatInfoListenerClose()
        log("⏹ Simulador Denon detenido")
    }

    private func beatInfoListenerClose() {
        beatListener?.close()
    }

    // MARK: - Reloj: hace avanzar los beats de las pistas simuladas

    private func runClock() {
        let tick = 0.05
        while !stopped {
            stateQueue.sync {
                for i in decks.indices where decks[i].playing {
                    decks[i].beat += (decks[i].bpm / 60.0) * tick
                    let totalBeats = decks[i].lengthSeconds * decks[i].bpm / 60.0
                    if decks[i].beat > totalBeats { decks[i].beat = 0 }
                }
            }
            Thread.sleep(forTimeInterval: tick)
        }
    }

    private func snapshot() -> [SimDeck] {
        stateQueue.sync { decks }
    }

    // MARK: - Anuncio por UDP

    private func runAnnounce() {
        guard let sock = try? UDPSocket(listenPort: nil) else {
            log("⚠️ Simulador: no se pudo crear el socket de anuncio")
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
            log("⚠️ Simulador: puerto \(DenonSimulator.mainPort) ocupado")
            return
        }
        mainListener = listener

        while !stopped {
            guard let conn = listener.accept() else { continue }
            log("🔌 La app se ha conectado a la conexión principal")
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
        log("📢 Servicios anunciados: StateMap y BeatInfo")

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
            log("⚠️ Simulador: puerto \(DenonSimulator.stateMapPort) ocupado")
            return
        }
        stateListener = listener

        while !stopped {
            guard let conn = listener.accept() else { continue }
            log("📊 La app se ha suscrito a StateMap")
            queue.async { [weak self] in self?.serveStateMap(conn) }
        }
        listener.close()
    }

    private func serveStateMap(_ conn: TCPConnection) {
        // Enviamos el estado completo al conectar y luego solo lo que cambia.
        sendFullState(conn)

        var lastPlaying: [Bool] = snapshot().map { $0.playing }
        while !stopped {
            _ = try? conn.receive() // consumimos las suscripciones que llegan
            let current = snapshot()
            for (index, deck) in current.enumerated() where index < lastPlaying.count {
                if deck.playing != lastPlaying[index] {
                    sendState(conn, path: "/Engine/Deck\(index + 1)/Play", json: boolJSON(deck.playing))
                    lastPlaying[index] = deck.playing
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        conn.close()
    }

    private func sendFullState(_ conn: TCPConnection) {
        let current = snapshot()
        var masterTempo = 0.0

        for (index, deck) in current.enumerated() {
            let n = index + 1
            if deck.isMaster { masterTempo = deck.bpm }

            sendState(conn, path: "/Engine/Deck\(n)/Track/SongLoaded", json: boolJSON(true))
            sendState(conn, path: "/Engine/Deck\(n)/Track/SongName", json: stringJSON(deck.title))
            sendState(conn, path: "/Engine/Deck\(n)/Track/ArtistName", json: stringJSON(deck.artist))
            sendState(conn, path: "/Engine/Deck\(n)/Track/CurrentKey", json: stringJSON(deck.key))
            sendState(conn, path: "/Engine/Deck\(n)/Track/Genre", json: stringJSON(deck.genre))
            sendState(conn, path: "/Engine/Deck\(n)/Track/TrackLength", json: numberJSON(deck.lengthSeconds))
            sendState(conn, path: "/Engine/Deck\(n)/Track/KeyLock", json: boolJSON(true))
            sendState(conn, path: "/Engine/Deck\(n)/Track/LoopEnableState", json: boolJSON(n == 2))
            sendState(conn, path: "/Engine/Deck\(n)/CurrentBPM", json: numberJSON(deck.bpm))
            sendState(conn, path: "/Engine/Deck\(n)/ExternalMixerVolume", json: numberJSON(n == 1 ? 0.85 : 0.6))
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
            log("⚠️ Simulador: puerto \(DenonSimulator.beatInfoPort) ocupado")
            return
        }
        beatListener = listener

        while !stopped {
            guard let conn = listener.accept() else { continue }
            log("🥁 La app se ha suscrito a BeatInfo")
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
                payload.writeFloat64(deck.beat)
                payload.writeFloat64(deck.lengthSeconds * deck.bpm / 60.0)
                payload.writeFloat64(deck.bpm)
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
            Thread.sleep(forTimeInterval: 0.05)
        }
        conn.close()
    }
}
