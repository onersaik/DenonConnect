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
    /// Bind UDP 51337. Vacío = OK. Si falla, la cabecera/empty state lo muestran.
    @Published public private(set) var listenWarning: String = ""

    private var devicesByKey: [String: StageLinqDevice] = [:]
    private let bookkeepingQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.bookkeeping")
    private let netQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.net", qos: .userInitiated, attributes: .concurrent)

    private var udpListener: UDPSocket?
    private var mainConnections: [String: NetworkDeviceConnection] = [:]
    private var serviceConnections: [String: [ServiceConnection]] = [:]
    private var connectingKeys: Set<String> = []
    private var serviceGeneration: [String: UInt64] = [:]
    private var stoppedFlag = false
    /// Un solo listener :51337. start() repetido no abre otro bind REUSEADDR.
    private var listenersStarted = false
    /// IPs a las que ya se logueó el primer unicast de identidad (nowplaying).
    private var loggedUnicastPeers: Set<String> = []
    /// Tokens/keys de auxiliares ya logueados (evitar spam HOWDY).
    private var ignoredAuxKeys: Set<String> = []
    /// Hasta esta fecha el anuncio HOWDY va a ~5 Hz (reconexión Ethernet).
    private var announceBurstUntil: Date = .distantPast
    /// Epoch de recuperación: StateMap/BeatInfo reinician con retry corto.
    private var recoveryEpoch: UInt64 = 0

    public init() {}

    /// Cable/Wi‑Fi de vuelta: HOWDY a tope + TCP StateMap/BeatInfo al momento.
    public func kickNetworkRecovery(reason: String) {
        guard bookkeepingQueue.sync(execute: { listenersStarted && !stoppedFlag }) else { return }
        log("StageLinq: recuperación rápida — \(reason)")
        bookkeepingQueue.sync {
            announceBurstUntil = Date().addingTimeInterval(4)
            recoveryEpoch &+= 1
            connectingKeys.removeAll()
        }
        let players: [StageLinqDevice] = bookkeepingQueue.sync {
            devicesByKey.values.filter { !$0.isAuxiliaryStageLinq && !$0.isDenonSimulator }
        }
        for (i, device) in players.enumerated() {
            scheduleReconnect(device, delay: 0.12 + Double(i) * 0.05)
        }
    }

    private var stopped: Bool {
        bookkeepingQueue.sync { stoppedFlag }
    }

    public func log(_ message: String) {
        ProtocolLog.append(message)
        DispatchQueue.main.async {
            self.logLines.append(message)
            if self.logLines.count > 400 {
                self.logLines.removeFirst(self.logLines.count - 400)
            }
        }
    }

    public func start() {
        let launch: Bool = bookkeepingQueue.sync {
            if listenersStarted { return false }
            listenersStarted = true
            stoppedFlag = false
            return true
        }
        guard launch else { return }
        log("StageLinq: arranque · \(NetworkInfo.lanIfacesLog()) · \(NetworkInfo.announceFromLog())")
        netQueue.async { [weak self] in self?.runDiscoveryListener() }
        netQueue.async { [weak self] in self?.runAnnounce() }
        netQueue.async { [weak self] in self?.runStalePrune() }
    }

    public func stop() {
        bookkeepingQueue.sync {
            stoppedFlag = true
            listenersStarted = false
        }
        udpListener?.close()
        bookkeepingQueue.sync {
            for (_, conn) in mainConnections { conn.stop() }
        }
    }

    // MARK: - Descubrimiento

    private func runDiscoveryListener() {
        do {
            let socket = try UDPSocket(listenPort: StageLinq.listenPort, reuse: .shared)
            udpListener = socket
            DispatchQueue.main.async { self.listenWarning = "" }
            log("StageLinq: bind UDP :\(StageLinq.listenPort) OK (0.0.0.0, REUSEADDR, sin REUSEPORT)")

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
            let hint = ListenPortReport.hint(for: StageLinq.listenPort)
            let msg = "UDP \(StageLinq.listenPort) ocupado: \(error). \(hint)"
            DispatchQueue.main.async { self.listenWarning = msg }
            log(msg)
        }
    }

    /// Identidad Now Playing (token SoundSwitch + `np2` / `nowplaying` / 2.2.0).
    /// El SC6000 trata este HOWDY como cliente legítimo; port 0 = no escuchamos
    /// TCP de vuelta, nos conectamos nosotros.
    private func identityPacket() -> Data {
        DiscoveryCodec.build(
            token: StageLinq.soundSwitchToken,
            source: StageLinq.identitySource,
            action: StageLinq.actionLogin,
            name: StageLinq.identityName,
            version: StageLinq.identityVersion,
            port: 0
        )
    }

    /// Peers HOWDY de LAN a los que cabe unicast de identidad.
    /// Excluye SIM / TEST en este Mac y el propio token.
    /// Incluye link-local 169.254 (SC6000 Wi‑Fi sin DHCP todavía).
    private func lanUnicastPeers() -> [(name: String, ip: String)] {
        bookkeepingQueue.sync {
            devicesByKey.values.compactMap { device in
                if device.isDenonSimulator { return nil }
                if device.isAuxiliaryStageLinq { return nil }
                guard Self.isStageLinqUnicastTarget(device.ip) else { return nil }
                return (device.name, device.ip)
            }
            .sorted { $0.ip < $1.ip }
        }
    }

    /// Como `isLANUnicastTarget` pero admite 169.254 (Wi‑Fi APIPA del SC6000).
    private static func isStageLinqUnicastTarget(_ ip: String) -> Bool {
        guard let bytes = NetworkInfo.ipv4Bytes(from: ip) else { return false }
        if bytes[0] == 127 { return false }
        if bytes == [255, 255, 255, 255] { return false }
        if NetworkInfo.isLocalIPv4(ip) { return false }
        return true
    }

    private func runAnnounce() {
        let packet = identityPacket()
        log("StageLinq: identidad \(StageLinq.identityName)/\(StageLinq.identitySource) v\(StageLinq.identityVersion) · HOWDY en todas las en* (Ethernet+Wi‑Fi+169.254) :\(StageLinq.listenPort) + unicast")
        log(NetworkInfo.lanIfacesLog())
        var lastIfaceSig = ""
        while !stopped {
            let burst = bookkeepingQueue.sync { Date() < announceBurstUntil }
            let ifaces = NetworkInfo.allLANAddresses()
            let sig = ifaces.map(\.description).joined(separator: "|")
            if sig != lastIfaceSig {
                lastIfaceSig = sig
                if ifaces.isEmpty {
                    log("StageLinq: sin IPv4 en en* — HOWDY no sale (utun/VPN no cuentan). Comprueba Wi‑Fi/Ethernet.")
                } else {
                    log("StageLinq: anunciando HOWDY por " + ifaces.map(\.description).joined(separator: ", "))
                    // Cambio de interfaz (cable enchufado) → burst inmediato.
                    bookkeepingQueue.sync { announceBurstUntil = Date().addingTimeInterval(3) }
                }
            }

            // Una salida por interfaz: IP_BOUND_IF en solo Ethernet perdía el SC6000 en Wi‑Fi.
            if ifaces.isEmpty {
                if let sock = try? UDPSocket(listenPort: nil) {
                    sock.send(packet, to: "255.255.255.255", port: StageLinq.listenPort)
                    sock.close()
                }
            } else {
                for lan in ifaces {
                    guard let sock = try? UDPSocket.boundToLAN(lan) else {
                        log("[WARN] StageLinq: no bind anuncio \(lan.description)")
                        continue
                    }
                    sock.send(packet, to: "255.255.255.255", port: StageLinq.listenPort)
                    if let directed = NetworkInfo.subnetBroadcast(for: lan) {
                        sock.send(packet, to: directed, port: StageLinq.listenPort)
                    }
                    sock.close()
                }
            }

            let peers = lanUnicastPeers()
            let liveIPs = Set(peers.map(\.ip))
            bookkeepingQueue.sync {
                loggedUnicastPeers = loggedUnicastPeers.intersection(liveIPs)
            }
            var sentIPs = Set<String>()
            for peer in peers {
                if !sentIPs.insert(peer.ip).inserted { continue }
                let peerLAN = NetworkInfo.lanAddress(reaching: peer.ip)
                if peerLAN.isValid, let bound = try? UDPSocket.boundToLAN(peerLAN) {
                    bound.send(packet, to: peer.ip, port: StageLinq.listenPort)
                    bound.close()
                } else if let sock = try? UDPSocket(listenPort: nil) {
                    sock.send(packet, to: peer.ip, port: StageLinq.listenPort)
                    sock.close()
                }
                let first: Bool = bookkeepingQueue.sync {
                    if loggedUnicastPeers.contains(peer.ip) { return false }
                    loggedUnicastPeers.insert(peer.ip)
                    return true
                }
                if first {
                    let via = peerLAN.isValid ? peerLAN.description : "sin LAN"
                    log("StageLinq: identidad \(StageLinq.identityName) unicast → \(peer.ip):\(StageLinq.listenPort) (\(peer.name)) vía \(via)")
                }
            }
            Thread.sleep(forTimeInterval: burst ? 0.2 : 1.0)
        }
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
            let newIP = info.address
            let newPort = info.port
            let ipChanged = !newIP.isEmpty && existing.ip != newIP
            let portChanged = newPort != 0 && existing.port != newPort
            if ipChanged || portChanged {
                let old = "\(existing.ip):\(existing.port)"
                existing.applyEndpoint(ip: newIP.isEmpty ? existing.ip : newIP,
                                       port: newPort != 0 ? newPort : existing.port)
                let via = NetworkInfo.lanAddress(reaching: existing.ip).description
                log("Denon: \(info.name) endpoint \(old) → \(existing.ip):\(existing.port) (mismo token; vía \(via))")
                bookkeepingQueue.sync {
                    mainConnections[existing.id]?.stop()
                    mainConnections.removeValue(forKey: existing.id)
                    connectingKeys.remove(existing.id)
                    loggedUnicastPeers.remove(old.split(separator: ":").first.map(String.init) ?? "")
                }
                DispatchQueue.main.async {
                    existing.connectionState = .discovered
                    existing.errorMessage = ""
                }
                connectToDevice(existing)
            }
            return
        }

        // OfflineAnalyzer / FileTransfer: no TCP ni fila de cabina (compiten con el player).
        let probe = StageLinqDevice(info: info)
        if probe.isAuxiliaryStageLinq {
            let first: Bool = bookkeepingQueue.sync {
                if ignoredAuxKeys.contains(key) { return false }
                ignoredAuxKeys.insert(key)
                return true
            }
            if first {
                log("Denon auxiliar: \(info.name) @ \(info.address):\(info.port) (ignorado; solo player)")
            }
            return
        }

        let device = probe
        bookkeepingQueue.sync { devicesByKey[key] = device }

        DispatchQueue.main.async {
            if !self.devices.contains(where: { $0.token == device.token && !device.token.isEmpty }) {
                self.devices.append(device)
                self.rosterRevision &+= 1
            }
        }
        let via = NetworkInfo.lanAddress(reaching: info.address)
        let viaTxt = via.isValid ? via.description : "sin match en*"
        log("Denon: \(info.name) · \(info.source) v\(info.version) @ \(info.address):\(info.port) · LAN \(viaTxt)")

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
            // 20 s: un SC6000 real puede perder HOWDY en Wi‑Fi sin estar apagado.
            // TCP conectado cuenta como vivo aunque el UDP llegue tarde.
            let stale: [StageLinqDevice] = bookkeepingQueue.sync {
                devicesByKey.values.filter { device in
                    guard now.timeIntervalSince(device.lastSeen) > 20.0 else { return false }
                    // TCP vivo o aún conectando: un SC6000 lento no se borra
                    // aunque el HOWDY UDP llegue tarde (Wi‑Fi).
                    if device.connectionState == .connected { return false }
                    if device.connectionState == .connecting { return false }
                    return true
                }
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
            connectingKeys.remove(device.id)
            loggedUnicastPeers.remove(device.ip)
            serviceGeneration[device.id, default: 0] &+= 1
            mainConnections[device.id]?.stop()
            mainConnections.removeValue(forKey: device.id)
            serviceConnections[device.id]?.forEach { $0.stop() }
            serviceConnections.removeValue(forKey: device.id)
        }
        DispatchQueue.main.async {
            self.devices.removeAll { $0.id == device.id }
            self.rosterRevision &+= 1
        }
        log(" Ausente: \(device.name) @ \(device.id) (\(reason))")
    }

    private func deviceStillKnown(_ device: StageLinqDevice) -> Bool {
        bookkeepingQueue.sync {
            devicesByKey.values.contains { $0.id == device.id }
        }
    }

    private func registerService(_ svc: ServiceConnection, device: StageLinqDevice) {
        bookkeepingQueue.sync {
            serviceConnections[device.id, default: []].append(svc)
        }
    }

    private func bumpServiceGeneration(_ device: StageLinqDevice) -> UInt64 {
        bookkeepingQueue.sync {
            serviceConnections[device.id]?.forEach { $0.stop() }
            serviceConnections[device.id] = []
            let g = (serviceGeneration[device.id] ?? 0) &+ 1
            serviceGeneration[device.id] = g
            return g
        }
    }

    private func currentServiceGeneration(_ device: StageLinqDevice) -> UInt64 {
        bookkeepingQueue.sync { serviceGeneration[device.id] ?? 0 }
    }

    /// TCP al puerto anunciado en HOWDY. Independiente del unicast UDP de
    /// identidad: `connectingKeys` evita doble connect; el unicast no toca esto.
    private func connectToDevice(_ device: StageLinqDevice) {
        let already: Bool = bookkeepingQueue.sync {
            if connectingKeys.contains(device.id) { return true }
            connectingKeys.insert(device.id)
            return false
        }
        if already { return }

        DispatchQueue.main.async { device.connectionState = .connecting }

        netQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.bookkeepingQueue.sync { _ = self.connectingKeys.remove(device.id) }
            }
            guard self.deviceStillKnown(device) else { return }

            self.bookkeepingQueue.sync { self.mainConnections[device.id]?.stop() }
            let generation = self.bumpServiceGeneration(device)
            let mainConn = NetworkDeviceConnection(host: device.ip, port: device.port, log: { [weak self] msg in self?.log(msg) })
            self.bookkeepingQueue.sync { self.mainConnections[device.id] = mainConn }

            // Cada servicio ("StateMap", "BeatInfo", ...) se conecta como mucho
            // una vez por ciclo de la conexión principal.
            var startedServiceNames = Set<String>()
            var announcedConnected = false

            do {
                try mainConn.run { services in
                    DispatchQueue.main.async {
                        device.services = services
                        if !announcedConnected {
                            announcedConnected = true
                            device.connectionState = .connected
                            self.log("Conectado: \(device.name) (\(device.ip)) — StateMap/BeatInfo")
                        }
                    }
                    if let statePort = services["StateMap"], !startedServiceNames.contains("StateMap") {
                        startedServiceNames.insert("StateMap")
                        self.netQueue.async { self.runStateMap(device: device, port: statePort, generation: generation) }
                    }
                    if let beatPort = services["BeatInfo"], !startedServiceNames.contains("BeatInfo") {
                        startedServiceNames.insert("BeatInfo")
                        self.netQueue.async { self.runBeatInfo(device: device, port: beatPort, generation: generation) }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    device.connectionState = .failed
                    device.errorMessage = "\(error)"
                }
                self.log("[WARN] \(device.name) TCP \(device.ip):\(device.port): \(error). Reintento (SC6000 en boot?)")
                // Retry agresivo: cable directo / recuperación Ethernet.
                self.scheduleReconnect(device, delay: 0.35)
            }
        }
    }

    private func scheduleReconnect(_ device: StageLinqDevice, delay: TimeInterval) {
        netQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.deviceStillKnown(device) else { return }
            self.connectToDevice(device)
        }
    }

    private func runStateMap(device: StageLinqDevice, port: UInt16, generation: UInt64) {
        var delay: TimeInterval = 0.2
        var epoch = bookkeepingQueue.sync { recoveryEpoch }
        while !stopped && deviceStillKnown(device) && currentServiceGeneration(device) == generation {
            let svc = StateMapService(host: device.ip, port: port, log: { [weak self] msg in self?.log(msg) })
            registerService(svc, device: device)
            do {
                try svc.run { path, value in
                    DispatchQueue.main.async {
                        let structural = path.hasSuffix("/SongLoaded")
                            || path.hasSuffix("/SongName")
                            || path.hasSuffix("/TrackName")
                            || path.hasSuffix("/ArtistName")
                            || path.hasSuffix("/CurrentBPM")
                            || path.hasSuffix("/TrackLength")
                            || path.hasSuffix("/Play")
                            || path.hasSuffix("/PlayState")
                        StageLinqManager.applyState(device: device, path: path, value: value)
                        if structural { self.rosterRevision &+= 1 }
                    }
                }
                return
            } catch {
                log("StateMap desconectado (\(device.name)): \(error). Reintento en \(String(format: "%.1f", delay))s")
            }
            guard !stopped && deviceStillKnown(device) && currentServiceGeneration(device) == generation else { return }
            let nowEpoch = bookkeepingQueue.sync { recoveryEpoch }
            if nowEpoch != epoch {
                epoch = nowEpoch
                delay = 0.12
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay + 0.4, 3)
        }
    }

    private func runBeatInfo(device: StageLinqDevice, port: UInt16, generation: UInt64) {
        var delay: TimeInterval = 0.2
        var epoch = bookkeepingQueue.sync { recoveryEpoch }
        while !stopped && deviceStillKnown(device) && currentServiceGeneration(device) == generation {
            let svc = BeatInfoService(host: device.ip, port: port, log: { [weak self] msg in self?.log(msg) })
            registerService(svc, device: device)
            do {
                try svc.run { beatData in
                    DispatchQueue.main.async {
                        StageLinqManager.applyBeat(device: device, beatData: beatData)
                    }
                }
                return
            } catch {
                log("BeatInfo desconectado (\(device.name)): \(error). Reintento en \(String(format: "%.1f", delay))s")
            }
            guard !stopped && deviceStillKnown(device) && currentServiceGeneration(device) == generation else { return }
            let nowEpoch = bookkeepingQueue.sync { recoveryEpoch }
            if nowEpoch != epoch {
                epoch = nowEpoch
                delay = 0.12
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay + 0.4, 3)
        }
    }

    // MARK: - Aplicar actualizaciones al modelo (siempre en el hilo principal)

    /// Paths de nowplaying ya logueados (una vez por deck+campo).
    private static var loggedNowPlayingKeys: Set<String> = []

    private static func logNowPlaying(_ device: StageLinqDevice, deck: Int, key: String, detail: String) {
        let token = "\(device.id)#\(deck)#\(key)"
        if loggedNowPlayingKeys.contains(token) { return }
        loggedNowPlayingKeys.insert(token)
        ProtocolLog.append("StateMap nowplaying Deck\(deck) \(key): \(detail) (\(device.name) @ \(device.ip))")
    }

    private static func applyState(device: StageLinqDevice, path: String, value: StateValue) {
        if path == "/Engine/Master/MasterTempo" {
            if let v = StateValueCodec.asDouble(value) { device.masterTempo = v }
            return
        }
        if path == "/Client/Preferences/Player" {
            if let s = StateValueCodec.asString(value), let n = Int(s) {
                device.playerNumber = n
            } else if let v = StateValueCodec.asDouble(value) {
                device.playerNumber = Int(v)
            }
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
            if let state = StateValueCodec.asBool(value) { deck.isMaster = state }
            return
        }
        if path.hasPrefix("/Mixer/CH"), path.hasSuffix("faderPosition") {
            let numChars = path.dropFirst("/Mixer/CH".count).prefix(while: { $0.isNumber })
            if let n = Int(numChars), n >= 1, n <= device.decks.count,
               let v = StateValueCodec.asDouble(value) {
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
            if let s = StateValueCodec.asBool(value) {
                deck.playState = s ? .playing : .stopped
                logNowPlaying(device, deck: deckNum, key: "Play", detail: s ? "true" : "false")
            }
        case "/PlayState":
            if let s = StateValueCodec.asBool(value) {
                deck.playState = s ? .playing : .stopped
                logNowPlaying(device, deck: deckNum, key: "PlayState", detail: s ? "play" : "stop")
            } else if let v = StateValueCodec.asDouble(value), let ps = PlayState(rawValue: Int(v)) {
                deck.playState = ps
                logNowPlaying(device, deck: deckNum, key: "PlayState", detail: "\(ps.rawValue)")
            }
        case "/PlayStatePath":
            if let s = StateValueCodec.asString(value) {
                let u = s.lowercased()
                if u.contains("play") && !u.contains("pause") {
                    deck.playState = .playing
                } else if u.contains("pause") {
                    deck.playState = .paused
                } else if u.contains("cue") || u.contains("stop") {
                    deck.playState = .stopped
                }
                logNowPlaying(device, deck: deckNum, key: "PlayStatePath", detail: s)
            }
        case "/CurrentBPM", "/Track/CurrentBPM":
            if let v = StateValueCodec.asDouble(value), v > 0 {
                deck.bpm = v
                logNowPlaying(device, deck: deckNum, key: "BPM", detail: String(format: "%.2f", v))
            }
        case "/Speed":
            if let v = StateValueCodec.asDouble(value), v > 0 {
                deck.speed = v
                logNowPlaying(device, deck: deckNum, key: "Speed", detail: String(format: "%.4f", v))
            }
        case "/ExternalMixerVolume":
            if let v = StateValueCodec.asDouble(value) { deck.volume = v }
        case "/ExternalScratchWheelTouch":
            if let s = StateValueCodec.asBool(value) { deck.scratchTouch = s }
        case "/Track/ArtistName":
            if let s = StateValueCodec.asString(value) {
                deck.trackArtist = s
                logNowPlaying(device, deck: deckNum, key: "Artist", detail: s)
            } else {
                logNowPlaying(device, deck: deckNum, key: "Artist", detail: "(vacío / sin string en StateMap)")
            }
        case "/Track/SongName", "/Track/TrackName":
            if let s = StateValueCodec.asString(value) {
                deck.trackTitle = s
                if !s.isEmpty {
                    deck.songLoaded = true
                    Self.ensureProceduralPeaks(deck: deck)
                }
                logNowPlaying(device, deck: deckNum, key: "Title", detail: s)
            }
        case "/Track/SongLoaded":
            if let s = StateValueCodec.asBool(value) {
                deck.songLoaded = s
                logNowPlaying(device, deck: deckNum, key: "SongLoaded", detail: s ? "true" : "false")
                if !s {
                    deck.trackTitle = ""
                    deck.trackArtist = ""
                    deck.liveBeat = 0
                    deck.currentBeat = 0
                    deck.totalBeats = 0
                    deck.peaks = []
                    deck.peaksLow = []
                    deck.peaksMid = []
                    deck.peaksHigh = []
                    deck.trackNetworkPath = ""
                }
            }
        case "/Track/CurrentKey":
            if let s = StateValueCodec.asString(value), MusicalKey.clean(s) != nil {
                deck.trackKey = MusicalKey.clean(s) ?? s
                logNowPlaying(device, deck: deckNum, key: "Key", detail: deck.trackKey)
            } else if let v = StateValueCodec.asDouble(value), let k = MusicalKey.fromIndex(Int(v)) {
                deck.trackKey = k
                logNowPlaying(device, deck: deckNum, key: "Key", detail: k)
            }
        case "/Track/CurrentKeyIndex":
            if let v = StateValueCodec.asDouble(value), let k = MusicalKey.fromIndex(Int(v)) {
                if deck.trackKey.isEmpty { deck.trackKey = k }
                logNowPlaying(device, deck: deckNum, key: "KeyIndex", detail: k)
            }
        case "/Track/TrackLength":
            if let v = StateValueCodec.asDouble(value), v > 0 {
                // Engine: segundos, o a veces ms. BeatInfo manda la verdad (totalBeats×60/BPM).
                let seconds = v > 10_000 ? v / 1000.0 : v
                if seconds > 3_600 { // >1h casi seguro basura para un deck
                    logNowPlaying(device, deck: deckNum, key: "Length",
                                  detail: String(format: "ignorado %.1f (usar BeatInfo)", seconds))
                } else {
                    deck.trackLength = seconds
                    logNowPlaying(device, deck: deckNum, key: "Length", detail: String(format: "%.1fs", seconds))
                }
            }
        case "/Track/Genre":
            if let s = StateValueCodec.asString(value) { deck.genre = s }
        case "/Track/LoopEnableState":
            if let s = StateValueCodec.asBool(value) { deck.loopEnabled = s }
        case "/Track/KeyLock":
            if let s = StateValueCodec.asBool(value) { deck.keyLock = s }
        case "/Track/CuePosition":
            if let v = StateValueCodec.asDouble(value) { deck.cuePosition = v }
        case "/Track/CurrentLoopInPosition":
            if let v = StateValueCodec.asDouble(value) { deck.loopInPosition = v }
        case "/Track/CurrentLoopOutPosition":
            if let v = StateValueCodec.asDouble(value) { deck.loopOutPosition = v }
        case "/Track/CurrentLoopSizeInBeats":
            if let v = StateValueCodec.asDouble(value) { deck.loopSizeBeats = v }
        case "/Track/TrackNetworkPath", "/Track/TrackUri":
            if let s = StateValueCodec.asString(value) {
                deck.trackNetworkPath = s
                logNowPlaying(device, deck: deckNum, key: "TrackPath", detail: s)
                Self.ensureProceduralPeaks(deck: deck)
                ProtocolLog.append("StateMap: TrackPath — waveform procedural generado")
            }
        default:
            break
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
            let crossedBeat = Int(beat.beat) != Int(deck.liveBeat)
            deck.liveBeat = beat.beat
            deck.beatReceivedAt = now
            // SwiftUI ≤20 Hz: currentBeat @Published tumba WaveformView si va a 60–100 Hz.
            // El playhead fluido lo pinta TimelineView 30 fps leyendo liveBeat + beatReceivedAt.
            if now.timeIntervalSince(deck.lastBeatUIPublish) >= 0.05 || crossedBeat {
                deck.lastBeatUIPublish = now
                deck.currentBeat = beat.beat
            }
            if abs(deck.totalBeats - beat.totalBeats) > 0.01 {
                deck.totalBeats = beat.totalBeats
            }
            if abs(deck.beatBpm - beat.bpm) > 0.05 {
                deck.beatBpm = beat.bpm
            }
            if beat.bpm > 0, abs(deck.bpm - beat.bpm) > 0.05 {
                deck.bpm = beat.bpm
            }
            // Duración real = totalBeats × 60 / BPM. StateMap TrackLength a veces llega basura.
            if beat.totalBeats > 0, beat.bpm > 0 {
                let fromBeats = beat.totalBeats * 60.0 / beat.bpm
                if fromBeats > 5, fromBeats < 3_600 {
                    if deck.trackLength <= 0
                        || deck.trackLength > fromBeats * 2.0
                        || deck.trackLength < fromBeats * 0.5 {
                        deck.trackLength = fromBeats
                        Self.ensureProceduralPeaks(deck: deck)
                    }
                }
            }
            if crossedBeat {
                deck.beatPulse.toggle()
            }
        }
        if !Self.loggedBeatInfoDevices.contains(device.id) {
            Self.loggedBeatInfoDevices.insert(device.id)
            let d0 = beatData.decks.first
            ProtocolLog.append(String(format:
                "BeatInfo vivo \(device.name): decks=%d beat=%.1f total=%.1f bpm=%.2f len≈%.1fs",
                beatData.decks.count,
                d0?.beat ?? 0,
                d0?.totalBeats ?? 0,
                d0?.bpm ?? 0,
                (d0 != nil && d0!.bpm > 0) ? d0!.totalBeats * 60.0 / d0!.bpm : 0
            ))
        }
    }

    private static var loggedBeatInfoDevices: Set<String> = []

    private static func extractDeckNumber(from path: String, prefix: String) -> Int? {
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let slashIdx = rest.firstIndex(of: "/") else { return nil }
        return Int(rest[rest.startIndex..<slashIdx])
    }

    /// Genera peaks procedurales si el deck no tiene peaks reales (FileTransfer).
    /// Determinista por título: misma pista = misma forma de onda visual.
    private static func ensureProceduralPeaks(deck: DeckState) {
        // Ya tiene peaks reales (FileTransfer o TestLink) → no pisar.
        if deck.peaksLow.count > 1 || deck.peaks.count > 1 { return }
        let title = deck.trackTitle
        guard !title.isEmpty else { return }
        var seed = 0
        for c in title.unicodeScalars { seed = seed &* 31 &+ Int(c.value) }
        let dur = deck.trackLength > 5 ? deck.trackLength : 240.0
        let wf = ProceduralWaveform.generate(seed: seed, duration: dur, columns: 2000)
        deck.peaks = (0..<wf.low.count).map { max(wf.low[$0], wf.mid[$0], wf.high[$0]) }
        deck.peaksLow = wf.low
        deck.peaksMid = wf.mid
        deck.peaksHigh = wf.high
    }
}
