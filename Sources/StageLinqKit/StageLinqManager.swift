// StageLinqManager.swift
// Orquesta el descubrimiento UDP y las conexiones a cada dispositivo,
// publicando el estado a SwiftUI a través de ObservableObject/@Published.
//
// Nota de diseño: deliberadamente NO se usa Swift Concurrency (async/await,
// actors) aquí. Todo el trabajo de red es bloqueante y corre en hilos de
// fondo (DispatchQueue), y cada actualización de estado observable se
// despacha explícitamente a DispatchQueue.main. Esto es más verboso pero
// mucho más predecible de escribir sin poder compilar/probar en el momento.

import Foundation
import Combine

public final class StageLinqManager: ObservableObject {
    @Published public private(set) var devices: [StageLinqDevice] = []
    @Published public private(set) var logLines: [String] = []
    /// Cambia cuando aparece/desaparece un deck con pista. ContentView no observa
    /// los DeckState anidados: sin esto la fila no nacería al cargar audio en TEST.
    @Published public private(set) var rosterRevision: UInt64 = 0

    private var devicesByKey: [String: StageLinqDevice] = [:]
    private let bookkeepingQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.bookkeeping")
    private let netQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.net", qos: .userInitiated, attributes: .concurrent)

    private var udpListener: UDPSocket?
    private var mainConnections: [String: NetworkDeviceConnection] = [:]
    private var stoppedFlag = false

    public init() {}

    private var stopped: Bool {
        bookkeepingQueue.sync { stoppedFlag }
    }

    public func log(_ message: String) {
        DispatchQueue.main.async {
            self.logLines.append(message)
            if self.logLines.count > 400 {
                self.logLines.removeFirst(self.logLines.count - 400)
            }
        }
    }

    public func start() {
        bookkeepingQueue.sync { stoppedFlag = false }
        netQueue.async { [weak self] in self?.runDiscoveryListener() }
        netQueue.async { [weak self] in self?.runAnnounce() }
        netQueue.async { [weak self] in self?.runStalePrune() }
    }

    public func stop() {
        bookkeepingQueue.sync { stoppedFlag = true }
        udpListener?.close()
        bookkeepingQueue.sync {
            for (_, conn) in mainConnections { conn.stop() }
        }
    }

    // MARK: - Descubrimiento

    private func runDiscoveryListener() {
        do {
            let socket = try UDPSocket(listenPort: StageLinq.listenPort)
            udpListener = socket
            log(" Escuchando dispositivos StageLinq en UDP :\(StageLinq.listenPort)")

            while !stopped {
                guard let (data, ip) = socket.receive() else { continue }
                guard var info = DiscoveryCodec.parse(data) else { continue }
                guard info.token != StageLinq.soundSwitchToken else { continue } // nuestro propio anuncio
                info.address = ip
                if info.action == StageLinq.actionLogout {
                    handleLogout(info)
                    continue
                }
                guard info.action == StageLinq.actionLogin else { continue }
                handleDiscovered(info)
            }
            socket.close()
        } catch {
            log(" No se pudo escuchar en UDP \(StageLinq.listenPort): \(error)")
        }
    }

    private func runAnnounce() {
        let packet = DiscoveryCodec.build(
            token: StageLinq.soundSwitchToken,
            source: StageLinq.identitySource,
            action: StageLinq.actionLogin,
            name: StageLinq.identityName,
            version: StageLinq.identityVersion,
            port: 0
        )
        guard let sock = try? UDPSocket(listenPort: nil) else {
            log("[WARN] No se pudo crear el socket de anuncio")
            return
        }
        while !stopped {
            sock.send(packet, to: "255.255.255.255", port: StageLinq.listenPort)
            Thread.sleep(forTimeInterval: 1.0)
        }
        sock.close()
    }

    // MARK: - Ciclo de vida por dispositivo

    /// Una unidad StageLinq = un token. El mismo SC6000 (o el simulador TEST)
    /// puede anunciarse por WiFi y por Ethernet; si se clavea por IP salen
    /// dos filas idénticas.
    private static func deviceKey(_ info: DiscoveryInfo) -> String {
        let token = info.token.map { String(format: "%02x", $0) }.joined()
        if token.isEmpty || token.allSatisfy({ $0 == "0" }) {
            return "\(info.address):\(info.port)"
        }
        return "tok-\(token)"
    }

    private func handleDiscovered(_ info: DiscoveryInfo) {
        let key = Self.deviceKey(info)

        let existing: StageLinqDevice? = bookkeepingQueue.sync {
            if let d = devicesByKey[key] { return d }
            return devicesByKey.values.first { $0.token == info.token && !info.token.isEmpty }
        }
        if let existing {
            existing.lastSeen = Date()
            return
        }

        let device = StageLinqDevice(info: info)
        bookkeepingQueue.sync { devicesByKey[key] = device }

        DispatchQueue.main.async {
            if !self.devices.contains(where: { $0.token == device.token && !device.token.isEmpty }) {
                self.devices.append(device)
                self.rosterRevision &+= 1
            }
        }
        log(" Descubierto: \(info.name) (\(info.source)) v\(info.version) @ \(info.address):\(info.port)")

        connectToDevice(device)
    }

    private func handleLogout(_ info: DiscoveryInfo) {
        let key = Self.deviceKey(info)
        let device: StageLinqDevice? = bookkeepingQueue.sync {
            if let d = devicesByKey[key] { return d }
            return devicesByKey.values.first { $0.token == info.token }
        }
        guard let device else { return }
        forget(device, reason: "logout")
    }

    private func runStalePrune() {
        while !stopped {
            Thread.sleep(forTimeInterval: 1.0)
            let now = Date()
            let stale: [StageLinqDevice] = bookkeepingQueue.sync {
                devicesByKey.values.filter { now.timeIntervalSince($0.lastSeen) > 3.0 }
            }
            for device in stale {
                forget(device, reason: "sin anuncio")
            }
        }
    }

    private func forget(_ device: StageLinqDevice, reason: String) {
        bookkeepingQueue.sync {
            let tokenKey = "tok-" + device.token.map { String(format: "%02x", $0) }.joined()
            devicesByKey.removeValue(forKey: tokenKey)
            devicesByKey.removeValue(forKey: device.id)
            mainConnections[device.id]?.stop()
            mainConnections.removeValue(forKey: device.id)
        }
        DispatchQueue.main.async {
            self.devices.removeAll { $0.id == device.id }
            self.rosterRevision &+= 1
        }
        log(" Ausente: \(device.name) @ \(device.id) (\(reason))")
    }

    private func connectToDevice(_ device: StageLinqDevice) {
        DispatchQueue.main.async { device.connectionState = .connecting }

        netQueue.async { [weak self] in
            guard let self else { return }
            let mainConn = NetworkDeviceConnection(host: device.ip, port: device.port, log: { [weak self] msg in self?.log(msg) })
            self.bookkeepingQueue.sync { self.mainConnections[device.id] = mainConn }

            // Cada servicio ("StateMap", "BeatInfo", ...) se conecta como mucho
            // una vez, sin importar cuántas veces se llame a este callback.
            var startedServiceNames = Set<String>()
            var announcedConnected = false

            do {
                try mainConn.run { services in
                    DispatchQueue.main.async {
                        device.services = services
                        if !announcedConnected {
                            announcedConnected = true
                            device.connectionState = .connected
                            self.log(" Conectado: \(device.name) (\(device.ip))")
                        }
                    }
                    if let statePort = services["StateMap"], !startedServiceNames.contains("StateMap") {
                        startedServiceNames.insert("StateMap")
                        self.netQueue.async { self.runStateMap(device: device, port: statePort) }
                    }
                    if let beatPort = services["BeatInfo"], !startedServiceNames.contains("BeatInfo") {
                        startedServiceNames.insert("BeatInfo")
                        self.netQueue.async { self.runBeatInfo(device: device, port: beatPort) }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    device.connectionState = .failed
                    device.errorMessage = "\(error)"
                }
                self.log("[WARN] \(device.name): \(error)")

                self.netQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.connectToDevice(device)
                }
            }
        }
    }

    private func runStateMap(device: StageLinqDevice, port: UInt16) {
        let svc = StateMapService(host: device.ip, port: port, log: { [weak self] msg in self?.log(msg) })
        do {
            try svc.run { path, value in
                DispatchQueue.main.async {
                    let structural = path.hasSuffix("/SongLoaded") || path.hasSuffix("/SongName")
                    StageLinqManager.applyState(device: device, path: path, value: value)
                    if structural { self.rosterRevision &+= 1 }
                }
            }
        } catch {
            log(" StateMap desconectado (\(device.name)): \(error)")
        }
    }

    private func runBeatInfo(device: StageLinqDevice, port: UInt16) {
        let svc = BeatInfoService(host: device.ip, port: port, log: { [weak self] msg in self?.log(msg) })
        do {
            try svc.run { beatData in
                DispatchQueue.main.async {
                    StageLinqManager.applyBeat(device: device, beatData: beatData)
                }
            }
        } catch {
            log(" BeatInfo desconectado (\(device.name)): \(error)")
        }
    }

    // MARK: - Aplicar actualizaciones al modelo (siempre en el hilo principal)

    private static func applyState(device: StageLinqDevice, path: String, value: StateValue) {
        if path == "/Engine/Master/MasterTempo" {
            if let v = value.value { device.masterTempo = v }
            return
        }
        if path == "/Client/Preferences/Player" {
            if let s = value.string, let n = Int(s) { device.playerNumber = n }
            return
        }
        if path.hasPrefix("/Client/Deck"), path.hasSuffix("/DeckIsMaster") {
            guard let deckNum = extractDeckNumber(from: path, prefix: "/Client/Deck") else { return }
            guard deckNum >= 1 && deckNum <= device.decks.count else { return }
            let deck = device.decks[deckNum - 1]
            let now = Date()
            deck.lastUpdate = now
            deck.lastPacketAt = now
            deck.pulseActivityIfNeeded()
            if let state = value.state { deck.isMaster = state }
            return
        }
        if path.hasPrefix("/Mixer/CH"), path.hasSuffix("faderPosition") {
            let numChars = path.dropFirst("/Mixer/CH".count).prefix(while: { $0.isNumber })
            if let n = Int(numChars), n >= 1, n <= device.decks.count, let v = value.value {
                let deck = device.decks[n - 1]
                deck.volume = v
                let now = Date()
                deck.lastUpdate = now
                deck.lastPacketAt = now
                deck.pulseActivityIfNeeded()
            }
            return
        }
        guard path.hasPrefix("/Engine/Deck") else { return }
        guard let deckNum = extractDeckNumber(from: path, prefix: "/Engine/Deck") else { return }
        guard deckNum >= 1 && deckNum <= device.decks.count else { return }
        let deck = device.decks[deckNum - 1]
        let suffix = String(path.dropFirst("/Engine/Deck\(deckNum)".count))
        let now = Date()
        deck.lastUpdate = now
        deck.lastPacketAt = now
        deck.pulseActivityIfNeeded()
        device.lastSeen = now

        switch suffix {
        case "/Play":
            if let s = value.state { deck.playState = s ? .playing : .stopped }
        case "/PlayState":
            if let s = value.state {
                deck.playState = s ? .playing : .stopped
            } else if let v = value.value, let ps = PlayState(rawValue: Int(v)) {
                deck.playState = ps
            }
        case "/CurrentBPM":
            if let v = value.value { deck.bpm = v }
        case "/Speed":
            if let v = value.value { deck.speed = v }
        case "/ExternalMixerVolume":
            if let v = value.value { deck.volume = v }
        case "/ExternalScratchWheelTouch":
            if let s = value.state { deck.scratchTouch = s }
        case "/Track/ArtistName":
            if let s = value.string { deck.trackArtist = s }
        case "/Track/SongName":
            if let s = value.string { deck.trackTitle = s }
        case "/Track/SongLoaded":
            if let s = value.state {
                deck.songLoaded = s
                if !s {
                    deck.trackTitle = ""
                    deck.trackArtist = ""
                    deck.currentBeat = 0
                    deck.totalBeats = 0
                }
            }
        case "/Track/CurrentKey":
            if let s = value.string, MusicalKey.clean(s) != nil {
                deck.trackKey = MusicalKey.clean(s) ?? s
            } else if let v = value.value, let k = MusicalKey.fromIndex(Int(v)) {
                deck.trackKey = k
            }
        case "/Track/CurrentKeyIndex":
            if let v = value.value, let k = MusicalKey.fromIndex(Int(v)) {
                if deck.trackKey.isEmpty { deck.trackKey = k }
            }
        case "/Track/TrackLength":
            if let v = value.value { deck.trackLength = v }
        case "/Track/Genre":
            if let s = value.string { deck.genre = s }
        case "/Track/LoopEnableState":
            if let s = value.state { deck.loopEnabled = s }
        case "/Track/KeyLock":
            if let s = value.state { deck.keyLock = s }
        case "/Track/CuePosition":
            if let v = value.value { deck.cuePosition = v }
        case "/Track/CurrentLoopInPosition":
            if let v = value.value { deck.loopInPosition = v }
        case "/Track/CurrentLoopOutPosition":
            if let v = value.value { deck.loopOutPosition = v }
        case "/Track/CurrentLoopSizeInBeats":
            if let v = value.value { deck.loopSizeBeats = v }
        default:
            break // el resto de las ~40 rutas suscritas se reciben pero no se
                   // muestran en la interfaz principal (loops rápidos, sample rate, etc.)
        }
    }

    private static func applyBeat(device: StageLinqDevice, beatData: BeatData) {
        let now = Date()
        device.lastSeen = now
        for (index, beat) in beatData.decks.enumerated() {
            guard index < device.decks.count else { break }
            let deck = device.decks[index]
            deck.lastPacketAt = now
            deck.pulseActivityIfNeeded()
            let crossedBeat = Int(beat.beat) != Int(deck.currentBeat)
            deck.currentBeat = beat.beat
            if abs(deck.totalBeats - beat.totalBeats) > 0.01 {
                deck.totalBeats = beat.totalBeats
            }
            if abs(deck.beatBpm - beat.bpm) > 0.001 {
                deck.beatBpm = beat.bpm
            }
            if beat.bpm > 0, abs(deck.bpm - beat.bpm) > 0.001 {
                deck.bpm = beat.bpm
            }
            if crossedBeat {
                deck.beatPulse.toggle()
            }
        }
    }

    private static func extractDeckNumber(from path: String, prefix: String) -> Int? {
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let slashIdx = rest.firstIndex(of: "/") else { return nil }
        return Int(rest[rest.startIndex..<slashIdx])
    }
}
