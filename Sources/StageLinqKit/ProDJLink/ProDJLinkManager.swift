// ProDJLinkManager.swift
// Descubrimiento y estado en vivo de reproductores Pioneer/AlphaTheta
// (CDJ-3000, CDJ-2000NXS2, XDJ, DJM) por Pro DJ Link.
//
// Funciona en tres hilos de fondo:
//   1. Escucha el puerto 50000 → descubre qué reproductores hay en la red.
//   2. Handshake de arranque (0x0a → 0x00 → 0x02 → 0x04, 3× cada uno) y
//      luego keepalive 0x06 cada 1,5 s, broadcast + unicast a cada CDJ 1–6.
//      Sin esto los CDJ a menudo NO envían estado detallado a 50002.
//   3. Escucha el puerto 50002 → recibe estado detallado ~5 veces por segundo.
//
// Mismo criterio de diseño que StageLinqManager: nada de Swift Concurrency,
// solo DispatchQueue y actualizaciones explícitas en el hilo principal.

import Foundation
import Combine

public final class ProDJLinkDevice: ObservableObject, Identifiable {
    public let id: String

    @Published public var playerNumber: Int
    @Published public var model: String
    @Published public var firmware: String = ""
    @Published public var ip: String

    @Published public var isPlaying: Bool = false
    @Published public var isMaster: Bool = false
    @Published public var isSynced: Bool = false
    @Published public var isOnAir: Bool = false

    @Published public var playModeLabel: String = "—"
    @Published public var trackLoaded: Bool = false
    @Published public var trackID: UInt32 = 0
    @Published public var trackTitle:  String = ""
    @Published public var trackArtist: String = ""
    @Published public var trackKey:    String = ""
    @Published public var trackGenre:  String = ""
    @Published public var trackAlbum:  String = ""
    @Published public var trackComment: String = ""
    @Published public var slotLabel: String = "—"
    /// Preview del CDJ (dbserver). Vacío = el protocolo no dio picos.
    @Published public var peaks: [UInt8] = []
    @Published public var peaksLow: [UInt8] = []
    @Published public var peaksMid: [UInt8] = []
    @Published public var peaksHigh: [UInt8] = []
    /// JPEG de dbserver GetArtwork (0x2003). Vacío = el CDJ no dio ID/blob.
    @Published public var artworkJPEG: Data = Data()

    @Published public var trackBPM: Double = 0
    @Published public var pitchPercent: Double = 0
    @Published public var faderPitchPercent: Double = 0
    @Published public var effectiveBPM: Double = 0

    @Published public var beatCount: Int = 0
    @Published public var beatInBar: Int = 0
    @Published public var beatPulse: Bool = false

    // Solo CDJ-3000: posición exacta de reproducción (puerto 50001).
    @Published public var trackLength: Double = 0   // segundos
    @Published public var playhead: Double = 0      // segundos
    @Published public var hasPosition: Bool = false

    public var remaining: Double { max(trackLength - (resolvedPlayhead ?? playhead), 0) }
    public var progress: Double {
        guard trackLength > 0, let head = resolvedPlayhead ?? (hasPosition ? playhead : nil) else { return 0 }
        return min(max(head / trackLength, 0), 1)
    }

    /// CDJ-3000: posición absoluta (50001). Resto: beat × 60 / BPM.
    public var resolvedPlayhead: Double? {
        if hasPosition { return playhead }
        let bpm = trackBPM > 0 ? trackBPM : effectiveBPM
        guard beatCount > 0, bpm > 0 else { return nil }
        return Double(beatCount) * 60.0 / bpm
    }

    /// CDJ virtual de STAGE CONNECT (player 7 / modelo propio). Nunca debe pintarse.
    public var isOwnVirtualCDJ: Bool {
        DJLink.isVirtualCDJ(playerNumber: playerNumber, model: model)
    }

    /// PioneerSimulator de STAGE CONNECT TEST en este Mac (misma IP, no player 7).
    /// Un CDJ de LAN tiene otra IP: nunca es local.
    public var isLocalTestSimulator: Bool {
        NetworkInfo.isLocalIPv4(ip) && !isOwnVirtualCDJ
    }

    /// CDJ de LAN con pista. Player 7, mixer, PioneerSimulator local y el
    /// reloj falso 131.95 no pintan. Un CDJ real en otra IP sí.
    public var isLANPlayerWithTrack: Bool {
        if isOwnVirtualCDJ { return false }
        if isMixer { return false }
        if isLocalTestSimulator { return false }
        if looksLikeLegacyFakeClock, NetworkInfo.isLocalIPv4(ip) { return false }
        return trackLoaded
    }

    /// Huella del reloj falso antiguo (130 BPM, +1.50%, 294 s).
    public var looksLikeLegacyFakeClock: Bool {
        DJLink.looksLikeLegacyFakeClock(
            playerNumber: playerNumber,
            pitchPercent: pitchPercent,
            trackBPM: trackBPM,
            effectiveBPM: effectiveBPM,
            trackLength: trackLength,
            trackID: trackID
        )
    }

    @Published public var hasStatus: Bool = false
    /// DJM / mixer embebido: se descubre pero no se pinta como CDJ.
    @Published public var isMixer: Bool = false
    /// No @Published: actualizarlo en cada paquete reventaba SwiftUI.
    public var lastSeen: Date = Date()
    /// Pulso limitado (~4 Hz) para el LED RX sin redibujar a cada datagrama.
    @Published public var activityTick: UInt8 = 0
    var lastActivityPublish: Date = .distantPast

    public init(playerNumber: Int, model: String, ip: String, isMixer: Bool = false) {
        self.id = "cdj-\(playerNumber)-\(ip)"
        self.playerNumber = playerNumber
        self.model = model
        self.ip = ip
        self.isMixer = isMixer
    }

    /// Enciende el LED RX sin saturar SwiftUI (máx. ~4 veces por segundo).
    func pulseActivityIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastActivityPublish) >= 0.22 else { return }
        lastActivityPublish = now
        activityTick &+= 1
    }
}

public final class ProDJLinkManager: ObservableObject {
    @Published public private(set) var devices: [ProDJLinkDevice] = []
    @Published public private(set) var logLines: [String] = []
    @Published public private(set) var rosterRevision: UInt64 = 0
    /// Bind 50000/50001/50002. Vacío = OK.
    @Published public private(set) var listenWarning: String = ""

    private var devicesByKey: [String: ProDJLinkDevice] = [:]
    private let bookkeepingQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.prodjlink.book")
    private let netQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.prodjlink.net", qos: .userInitiated, attributes: .concurrent)

    private var keepAliveSocket: UDPSocket?
    private var statusSocket: UDPSocket?
    private var beatSocket: UDPSocket?
    private var loggedUnicastPeers: Set<String> = []
    private var stoppedFlag = false
    private var loggedIgnoreKeys: Set<String> = []
    private var loggedStatusKeys: Set<String> = []
    private var loggedHelloKeys: Set<String> = []
    private var loggedMixerKeys: Set<String> = []
    private var loggedMissingTitle: Set<String> = []
    private var recentHellos: [String: (model: String, at: Date)] = [:]
    private var metaCache: [String: DBServerMeta] = [:]
    private var waveformCache: [String: DBServerWaveform] = [:]
    private var artworkCache: [String: Data] = [:]
    /// Handshake 0x0a→0x00→0x02→0x04 ya se envió. Un CDJ de LAN que aparece
    /// después recibe otra ráfaga (broadcast no basta si llegó tarde).
    private var startupClaimsDone = false
    private var lateHandshakePending = false

    public init() {}

    private var stopped: Bool { bookkeepingQueue.sync { stoppedFlag } }

    public func log(_ message: String) {
        DispatchQueue.main.async {
            self.logLines.append(message)
            if self.logLines.count > 400 {
                self.logLines.removeFirst(self.logLines.count - 400)
            }
        }
    }

    public func start() {
        bookkeepingQueue.sync {
            stoppedFlag = false
            startupClaimsDone = false
            lateHandshakePending = false
        }
        log("Pro DJ Link: arranque · \(NetworkInfo.lanIfacesLog()) · \(NetworkInfo.announceFromLog())")
        netQueue.async { [weak self] in self?.runKeepAliveListener() }
        netQueue.async { [weak self] in self?.runStatusListener() }
        netQueue.async { [weak self] in self?.runBeatListener() }
        netQueue.async { [weak self] in self?.runVirtualCDJAnnounce() }
        netQueue.async { [weak self] in self?.runStalePrune() }
    }

    public func stop() {
        bookkeepingQueue.sync { stoppedFlag = true }
        keepAliveSocket?.close()
        statusSocket?.close()
        beatSocket?.close()
    }

    // MARK: - 1. Descubrimiento (puerto 50000)

    private func runKeepAliveListener() {
        do {
            let socket = try UDPSocket(listenPort: DJLink.keepAlivePort, reuse: .shared)
            keepAliveSocket = socket
            setListenWarning(port: DJLink.keepAlivePort, error: nil)
            log("Pro DJ Link: bind UDP :\(DJLink.keepAlivePort) OK (0.0.0.0, REUSEADDR, sin REUSEPORT)")

            while !stopped {
                guard let (data, fromIP) = socket.receive() else { continue }
                guard let announce = DJLinkKeepAlive.parse(data) else { continue }
                handleAnnounce(announce, fromIP: fromIP)
            }
            socket.close()
        } catch {
            setListenWarning(port: DJLink.keepAlivePort, error: error)
            log("Pro DJ Link: UDP \(DJLink.keepAlivePort) ocupado: \(error). \(ListenPortReport.hint(for: DJLink.keepAlivePort))")
        }
    }

    private func setListenWarning(port: UInt16, error: Error?) {
        DispatchQueue.main.async {
            if let error {
                let line = "UDP \(port) ocupado: \(error). \(ListenPortReport.hint(for: port))"
                if self.listenWarning.contains("UDP \(port)") {
                    return
                }
                if self.listenWarning.isEmpty {
                    self.listenWarning = line
                } else {
                    self.listenWarning += "  ·  " + line
                }
            }
        }
    }

    private func noteIgnored(_ key: String, detail: String) {
        let first: Bool = bookkeepingQueue.sync {
            if loggedIgnoreKeys.contains(key) { return false }
            loggedIgnoreKeys.insert(key)
            return true
        }
        if first { log(" Pioneer local ignorado: \(detail)") }
    }

    private func dropDeviceIfPresent(playerNumber: Int) {
        let key = String(playerNumber)
        let existed: Bool = bookkeepingQueue.sync {
            guard devicesByKey[key] != nil else { return false }
            devicesByKey.removeValue(forKey: key)
            return true
        }
        guard existed else { return }
        DispatchQueue.main.async {
            self.devices.removeAll { $0.playerNumber == playerNumber }
        }
    }

    private func handleAnnounce(_ announce: DJLinkKeepAlive, fromIP: String) {
        // Un reproductor = una fila. La IP del datagrama es la real; el campo
        // del paquete a veces llega a 0.0.0.0 y duplicaba el dispositivo.
        let ip = fromIP.isEmpty ? announce.ip : fromIP
        if !ip.isEmpty, !announce.model.isEmpty || announce.packetType == DJLink.PacketType.hello {
            rememberHello(ip: ip, model: announce.model)
        }
        if DJLink.isVirtualCDJ(playerNumber: announce.playerNumber, model: announce.model) {
            return
        }
        if announce.isMixer {
            noteMixer(announce, ip: ip)
            return
        }
        if !announce.hasStableIdentity || announce.playerNumber <= 0 {
            noteHello(announce, ip: ip)
            return
        }
        if DJLink.shouldIgnoreIncomingPioneer(
            playerNumber: announce.playerNumber, model: announce.model, ip: ip
        ) {
            dropDeviceIfPresent(playerNumber: announce.playerNumber)
            noteIgnored(
                "\(announce.playerNumber)@\(ip)",
                detail: "\(announce.model.isEmpty ? "CDJ" : announce.model) player \(announce.playerNumber) @ \(ip)"
            )
            return
        }
        upsertPlayer(
            playerNumber: announce.playerNumber,
            model: announce.model,
            ip: ip,
            isMixer: false,
            source: announce.packetType
        )
    }

    private func rememberHello(ip: String, model: String) {
        bookkeepingQueue.async {
            self.recentHellos[ip] = (model, Date())
            let cutoff = Date().addingTimeInterval(-30)
            self.recentHellos = self.recentHellos.filter { $0.value.at >= cutoff }
        }
    }

    private func noteHello(_ announce: DJLinkKeepAlive, ip: String) {
        let key = "hello-\(announce.packetType)-\(ip)-\(announce.model)"
        let first: Bool = bookkeepingQueue.sync {
            if loggedHelloKeys.contains(key) { return false }
            loggedHelloKeys.insert(key)
            return true
        }
        guard first else { return }
        let typeHex = String(format: "0x%02x", announce.packetType)
        let name = announce.model.isEmpty ? "Pioneer" : announce.model
        log("Pro DJ Link: \(name) @ \(ip) tipo \(typeHex) (hello/claim, esperando player)")
    }

    private func noteMixer(_ announce: DJLinkKeepAlive, ip: String) {
        let key = "mixer-\(announce.playerNumber)@\(ip)"
        let first: Bool = bookkeepingQueue.sync {
            if loggedMixerKeys.contains(key) { return false }
            loggedMixerKeys.insert(key)
            return true
        }
        guard first else { return }
        let name = announce.model.isEmpty ? "DJM" : announce.model
        let player = announce.playerNumber > 0 ? " player \(announce.playerNumber)" : ""
        log("Pro DJ Link: \(name)\(player) @ \(ip) (mixer, no se pinta como CDJ)")
    }

    /// Una fila por número de player. No duplica si ya está (keepalive + claim).
    @discardableResult
    private func upsertPlayer(
        playerNumber: Int,
        model: String,
        ip: String,
        isMixer: Bool,
        source: UInt8
    ) -> ProDJLinkDevice? {
        if isMixer { return nil }
        let key = String(playerNumber)
        let existing: ProDJLinkDevice? = bookkeepingQueue.sync { devicesByKey[key] }

        if let device = existing {
            device.lastSeen = Date()
            DispatchQueue.main.async {
                if device.ip != ip { device.ip = ip }
                if !model.isEmpty, device.model != model { device.model = model }
                if device.isMixer != isMixer { device.isMixer = isMixer }
            }
            return device
        }

        let device = ProDJLinkDevice(
            playerNumber: playerNumber, model: model, ip: ip, isMixer: isMixer
        )
        bookkeepingQueue.sync {
            devicesByKey[key] = device
            if NetworkInfo.isLANUnicastTarget(ip), startupClaimsDone {
                lateHandshakePending = true
            }
        }
        DispatchQueue.main.async {
            if !self.devices.contains(where: { $0.playerNumber == device.playerNumber }) {
                self.devices.append(device)
                self.devices.sort { $0.playerNumber < $1.playerNumber }
            }
        }
        let typeHex = String(format: "0x%02x", source)
        log("CDJ: \(model.isEmpty ? "Pioneer" : model) · player \(playerNumber) @ \(ip) (tipo \(typeHex))")
        return device
    }

    // MARK: - 2. Anuncio como CDJ virtual (imprescindible)

    /// Peers LAN (player 1–6) a los que hay que unicast el keepalive virtual.
    /// TEST localhost / Dual en este Mac no entran: `isLANUnicastTarget`.
    private func lanUnicastPeers() -> [(player: Int, ip: String)] {
        bookkeepingQueue.sync {
            devicesByKey.values.compactMap { device in
                let player = device.playerNumber
                guard (1...6).contains(player), !device.isMixer else { return nil }
                let ip = device.ip
                guard NetworkInfo.isLANUnicastTarget(ip) else { return nil }
                return (player, ip)
            }
            .sorted { $0.player < $1.player }
        }
    }

    private func virtualKeepAlivePacket(ip: [UInt8], mac: [UInt8]) -> Data {
        DJLinkKeepAlive.buildVirtualCDJ(
            playerNumber: DJLink.virtualPlayerNumber,
            model: DJLink.virtualModelName,
            ip: ip,
            mac: mac
        )
    }

    /// Broadcast 255.255.255.255:50000 y unicast a cada CDJ 1–6 de LAN.
    /// Si el peer está en otra iface, reconstruye IP/MAC locales.
    private func emitVirtualAnnounce(
        _ sock: UDPSocket,
        defaultIP: [UInt8],
        defaultMAC: [UInt8],
        logUnicast: Bool = false,
        build: (_ ip: [UInt8], _ mac: [UInt8]) -> Data
    ) {
        let broadcastPacket = build(defaultIP, defaultMAC)
        sock.send(broadcastPacket, to: "255.255.255.255", port: DJLink.keepAlivePort)

        let peers = lanUnicastPeers()
        let liveIPs = Set(peers.map(\.ip))
        bookkeepingQueue.sync {
            loggedUnicastPeers = loggedUnicastPeers.intersection(liveIPs)
        }

        var sentIPs = Set<String>()
        for peer in peers {
            if !sentIPs.insert(peer.ip).inserted { continue }
            let peerLAN = NetworkInfo.lanAddress(reaching: peer.ip)
            guard peerLAN.isValid else { continue }
            let peerIPBytes = peerLAN.ip
            let packet: Data
            if peerIPBytes == defaultIP {
                packet = broadcastPacket
            } else {
                packet = build(
                    peerIPBytes,
                    NetworkInfo.localMACBytes(forIPv4: peerIPBytes)
                )
            }
            if peerIPBytes == defaultIP {
                sock.send(packet, to: peer.ip, port: DJLink.keepAlivePort)
            } else {
                sendAnnounce(packet, to: peer.ip, port: DJLink.keepAlivePort, from: peerLAN, fallback: sock)
            }
            guard logUnicast else { continue }
            let first: Bool = bookkeepingQueue.sync {
                if loggedUnicastPeers.contains(peer.ip) { return false }
                loggedUnicastPeers.insert(peer.ip)
                return true
            }
            if first {
                log("Pro DJ Link: keepalive player \(DJLink.virtualPlayerNumber) unicast → \(peer.ip):\(DJLink.keepAlivePort) (CDJ \(peer.player), IP local \(NetworkInfo.describe(peerIPBytes)))")
            }
        }
    }

    /// Secuencia de arranque (Now Playing / beat-link / dysentery):
    /// 0x0a×3 → 0x00×3 → 0x02×3 → 0x04×3 a ~300 ms. 0x00 nunca pone player en 0x24.
    private func runStartupClaims(sock: UDPSocket, ip: [UInt8], mac: [UInt8]) {
        let model = DJLink.virtualModelName
        let player = DJLink.virtualPlayerNumber
        log("Pro DJ Link: handshake virtual player \(player) · 0x0a×3 → 0x00×3 → 0x02×3 → 0x04×3 (broadcast+unicast) · luego 0x06 cada 1.5s")

        for _ in 1...3 {
            if stopped { return }
            emitVirtualAnnounce(sock, defaultIP: ip, defaultMAC: mac) { _, _ in
                DJLinkKeepAlive.buildVirtualHello(model: model)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        for n in 1...3 {
            if stopped { return }
            let counter = UInt8(n)
            emitVirtualAnnounce(sock, defaultIP: ip, defaultMAC: mac) { _, peerMAC in
                DJLinkKeepAlive.buildVirtualClaim1(counter: counter, model: model, mac: peerMAC)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        for n in 1...3 {
            if stopped { return }
            let counter = UInt8(n)
            emitVirtualAnnounce(sock, defaultIP: ip, defaultMAC: mac) { peerIP, peerMAC in
                DJLinkKeepAlive.buildVirtualClaim2(
                    counter: counter, playerNumber: player, model: model, ip: peerIP, mac: peerMAC
                )
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        for n in 1...3 {
            if stopped { return }
            let counter = UInt8(n)
            emitVirtualAnnounce(sock, defaultIP: ip, defaultMAC: mac) { _, _ in
                DJLinkKeepAlive.buildVirtualClaim3(counter: counter, playerNumber: player, model: model)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func sendAnnounce(
        _ data: Data,
        to host: String,
        port: UInt16,
        from lan: LANAddress,
        fallback: UDPSocket
    ) {
        if !lan.isValid {
            fallback.send(data, to: host, port: port)
            return
        }
        if let bound = try? UDPSocket.boundToLAN(lan) {
            bound.send(data, to: host, port: port)
            bound.close()
            return
        }
        fallback.send(data, to: host, port: port)
    }

    private func logVirtualIdentity(lan: LANAddress, ip: [UInt8], mac: [UInt8]) {
        let macTxt = NetworkInfo.describeMAC(mac)
        let player = DJLink.virtualPlayerNumber
        if !lan.isValid || ip == [0, 0, 0, 0] {
            log("Pro DJ Link: CDJ virtual player \(player) sin IPv4 LAN; MAC \(macTxt) — solo broadcast (los CDJ pueden ignorar 0.0.0.0)")
            return
        }
        if mac.allSatisfy({ $0 == 0 }) {
            log("[AVISO] Pro DJ Link: CDJ virtual player \(player) MAC 00:00:00:00:00:00 @ \(lan.description) — los CDJ ignoran el anuncio")
            return
        }
        log("Pro DJ Link: CDJ virtual player \(player) · \(lan.description) · MAC \(macTxt)")
    }

    private func runVirtualCDJAnnounce() {
        var lan = NetworkInfo.preferredLAN()
        guard var sock = (try? UDPSocket.boundToLAN(lan)) ?? (try? UDPSocket(listenPort: nil)) else {
            log("[AVISO] Pro DJ Link: no se pudo crear el socket de anuncio")
            return
        }
        var lastBroadcastIP: [UInt8] = []

        let startIP = lan.ip
        let startMAC = NetworkInfo.localMACBytes(forIPv4: startIP)
        lastBroadcastIP = startIP
        logVirtualIdentity(lan: lan, ip: startIP, mac: startMAC)
        runStartupClaims(sock: sock, ip: startIP, mac: startMAC)
        bookkeepingQueue.sync { startupClaimsDone = true }

        while !stopped {
            let next = NetworkInfo.preferredLAN()
            if next != lan {
                sock.close()
                lan = next
                sock = (try? UDPSocket.boundToLAN(lan)) ?? (try? UDPSocket(listenPort: nil)) ?? sock
            }
            let ipBytes = lan.ip
            let macBytes = NetworkInfo.localMACBytes(forIPv4: ipBytes)
            if ipBytes != lastBroadcastIP {
                lastBroadcastIP = ipBytes
                logVirtualIdentity(lan: lan, ip: ipBytes, mac: macBytes)
            }

            let redoHandshake = bookkeepingQueue.sync {
                let pending = lateHandshakePending
                lateHandshakePending = false
                return pending
            }
            if redoHandshake {
                log("Pro DJ Link: CDJ de LAN nuevo — handshake 0x0a×3 → 0x00×3 → 0x02×3 → 0x04×3 (broadcast+unicast)")
                runStartupClaims(sock: sock, ip: ipBytes, mac: macBytes)
            }

            emitVirtualAnnounce(
                sock, defaultIP: ipBytes, defaultMAC: macBytes, logUnicast: true
            ) { ip, mac in
                self.virtualKeepAlivePacket(ip: ip, mac: mac)
            }

            Thread.sleep(forTimeInterval: 1.5)
        }
        sock.close()
    }

    // MARK: - 3. Estado detallado (puerto 50002)

    private func runStatusListener() {
        do {
            let socket = try UDPSocket(listenPort: DJLink.statusPort, reuse: .unicast)
            statusSocket = socket
            setListenWarning(port: DJLink.statusPort, error: nil)
            log("Pro DJ Link: bind UDP :\(DJLink.statusPort) OK (exclusivo, sin REUSEADDR/REUSEPORT)")

            while !stopped {
                guard let (data, ip) = socket.receive() else { continue }
                guard let status = CDJStatus.parse(data) else { continue }
                applyStatus(status, ip: ip)
            }
            socket.close()
        } catch {
            setListenWarning(port: DJLink.statusPort, error: error)
            log("Pro DJ Link: UDP \(DJLink.statusPort) ocupado: \(error). \(ListenPortReport.hint(for: DJLink.statusPort))")
        }
    }

    // MARK: - 4. Beats y posición exacta (puerto 50001)

    private func runBeatListener() {
        do {
            let socket = try UDPSocket(listenPort: DJLink.beatPort, reuse: .unicast)
            beatSocket = socket
            setListenWarning(port: DJLink.beatPort, error: nil)
            log("Pro DJ Link: bind UDP :\(DJLink.beatPort) OK (exclusivo, sin REUSEADDR/REUSEPORT)")

            while !stopped {
                guard let (data, ip) = socket.receive() else { continue }
                guard let parsed = DJLinkBeatPacket.parse(data) else { continue }
                switch parsed {
                case .beat(let beat):
                    applyBeat(beat, ip: ip)
                case .position(let pos):
                    applyPosition(pos, ip: ip)
                }
            }
            socket.close()
        } catch {
            setListenWarning(port: DJLink.beatPort, error: error)
            log("Pro DJ Link: UDP \(DJLink.beatPort) ocupado: \(error). \(ListenPortReport.hint(for: DJLink.beatPort))")
        }
    }

    // MARK: - 5. Caducar CDJ que ya no anuncian (Pioneer TEST al apagar)

    private func runStalePrune() {
        while !stopped {
            Thread.sleep(forTimeInterval: 0.5)
            let now = Date()
            let stale: [ProDJLinkDevice] = bookkeepingQueue.sync {
                devicesByKey.values.filter { now.timeIntervalSince($0.lastSeen) > 20.0 }
            }
            guard !stale.isEmpty else { continue }
            let keys = stale.map { String($0.playerNumber) }
            bookkeepingQueue.sync {
                for key in keys {
                    devicesByKey.removeValue(forKey: key)
                    loggedStatusKeys.remove(key)
                }
                for d in stale { loggedUnicastPeers.remove(d.ip) }
            }
            DispatchQueue.main.async {
                self.devices.removeAll { device in
                    stale.contains { $0.playerNumber == device.playerNumber }
                }
            }
            for d in stale {
                log(" CDJ ausente: \(d.model) · reproductor \(d.playerNumber)")
            }
        }
    }

    /// CDJ de LAN cuyo anuncio 50000 no fue 0x06 (hello/claim). El status
    /// local del simulador TEST no crea fila.
    private func adoptLANPlayerFromStatus(_ status: CDJStatus, ip: String) -> ProDJLinkDevice? {
        if NetworkInfo.isLocalIPv4(ip) { return nil }
        if status.playerNumber < 1 || status.playerNumber > 6 { return nil }
        if DJLink.shouldIgnoreIncomingPioneer(
            playerNumber: status.playerNumber, model: status.model, ip: ip, firmware: status.firmware
        ) { return nil }
        if DJLinkDeviceKind.infer(model: status.model, playerNumber: status.playerNumber) == .mixer {
            return nil
        }
        let remembered: String = bookkeepingQueue.sync {
            recentHellos[ip]?.model ?? ""
        }
        let model = status.model.isEmpty ? remembered : status.model
        return upsertPlayer(
            playerNumber: status.playerNumber,
            model: model,
            ip: ip,
            isMixer: false,
            source: DJLink.PacketType.cdjStatus
        )
    }

    private func applyMeta(_ meta: DBServerMeta, to target: ProDJLinkDevice) {
        if !meta.title.isEmpty { target.trackTitle = meta.title }
        if !meta.artist.isEmpty { target.trackArtist = meta.artist }
        if !meta.key.isEmpty { target.trackKey = meta.key }
        if !meta.genre.isEmpty { target.trackGenre = meta.genre }
        if !meta.album.isEmpty { target.trackAlbum = meta.album }
        if !meta.comment.isEmpty { target.trackComment = meta.comment }
    }

    private func fetchArtwork(
        ip: String, slot: Int, artworkId: UInt32,
        queryPlayer: UInt8, key: String, newID: UInt32, target: ProDJLinkDevice
    ) {
        netQueue.async { [weak self, weak target] in
            guard let self, let target else { return }
            guard let jpeg = DBServerClient.queryArtwork(
                ip: ip, slot: slot, artworkId: artworkId, queryPlayer: queryPlayer
            ) else { return }
            self.bookkeepingQueue.async { self.artworkCache[key] = jpeg }
            DispatchQueue.main.async {
                guard target.trackID == newID else { return }
                target.artworkJPEG = jpeg
            }
            self.log("dbserver: portada \(jpeg.count) B (artwork \(artworkId))")
        }
    }

    /// Player en el TCP dbserver: 0 (ordenador) o el primer hueco 1–6.
    /// No se anuncia en UDP como ese número (el virtual sigue siendo 7).
    private func dbserverQueryPlayers() -> [UInt8] {
        let occupied: Set<Int> = bookkeepingQueue.sync {
            Set(devicesByKey.values.compactMap { device in
                let n = device.playerNumber
                guard (1...6).contains(n), !device.isMixer else { return nil }
                return n
            })
        }
        var list: [UInt8] = [0]
        for n in 1...6 where !occupied.contains(n) {
            list.append(UInt8(n))
            break
        }
        return list
    }

    private func noteMissingTitle(player: Int, trackID: UInt32, slot: Int, asQuery: UInt8? = nil) {
        let key = "\(player):\(slot):\(trackID)"
        let first: Bool = bookkeepingQueue.sync {
            if loggedMissingTitle.contains(key) { return false }
            loggedMissingTitle.insert(key)
            return true
        }
        guard first else { return }
        if let asQuery {
            log("CDJ player \(player): trackID \(trackID) sin nombre — dbserver rechazó consulta como player \(asQuery) (slot \(slot), sin anunciar)")
        } else {
            log("CDJ player \(player): trackID \(trackID) sin nombre (dbserver no respondió, slot \(slot))")
        }
    }

    /// Un CDJ se identifica por número de reproductor (1–6). No se crean
    /// dispositivos a partir de paquetes de estado locales: si el keepalive
    /// paró, un status rezagado no debe resucitar un fantasma TEST.
    private func deviceForPlayer(_ playerNumber: Int, ip: String, model: String = "", firmware: String = "") -> ProDJLinkDevice? {
        if DJLink.shouldIgnoreIncomingPioneer(
            playerNumber: playerNumber, model: model, ip: ip, firmware: firmware
        ) {
            dropDeviceIfPresent(playerNumber: playerNumber)
            return nil
        }
        return bookkeepingQueue.sync { devicesByKey[String(playerNumber)] }
    }

    private func applyBeat(_ beat: DJLinkBeat, ip: String) {
        guard let target = deviceForPlayer(beat.playerNumber, ip: ip) else { return }
        target.lastSeen = Date()
        // Pioneer TEST: el overlay de TestLink pinta beat/playhead. Si también
        // aplicamos el UDP, la fila parpadea (MASTER, compás, waveform).
        if NetworkInfo.isLocalIPv4(ip) { return }
        DispatchQueue.main.async {
            target.pulseActivityIfNeeded()
            if target.beatInBar != beat.beatInBar {
                target.beatInBar = beat.beatInBar
                target.beatPulse.toggle()
            }
            if beat.bpm > 0, abs(target.trackBPM - beat.bpm) > 0.05 {
                target.trackBPM = beat.bpm
            }
            if abs(beat.pitchPercent) > 0.01, abs(target.pitchPercent - beat.pitchPercent) > 0.05 {
                target.pitchPercent = beat.pitchPercent
            }
            if beat.bpm > 0 {
                let eff = beat.bpm * (1.0 + beat.pitchPercent / 100.0)
                if abs(target.effectiveBPM - eff) > 0.05 { target.effectiveBPM = eff }
            }
        }
    }

    private func applyPosition(_ pos: DJLinkAbsolutePosition, ip: String) {
        guard let target = deviceForPlayer(pos.playerNumber, ip: ip) else { return }
        // El reloj falso antiguo solo se tira si sale de ESTE Mac. Un CDJ real
        // a 130 BPM +1.50% no se descarta.
        if NetworkInfo.isLocalIPv4(ip), DJLink.looksLikeLegacyFakeClock(
            playerNumber: pos.playerNumber,
            pitchPercent: target.pitchPercent,
            trackBPM: target.trackBPM,
            effectiveBPM: target.effectiveBPM,
            trackLength: pos.trackLength,
            trackID: target.trackID
        ) {
            dropDeviceIfPresent(playerNumber: pos.playerNumber)
            return
        }
        target.lastSeen = Date()
        if NetworkInfo.isLocalIPv4(ip) { return }
        DispatchQueue.main.async {
            target.pulseActivityIfNeeded()
            if abs(target.trackLength - pos.trackLength) > 0.01 { target.trackLength = pos.trackLength }
            if abs(target.playhead - pos.playhead) > 0.001 { target.playhead = pos.playhead }
            if !target.hasPosition { target.hasPosition = true }
        }
    }

    private func applyStatus(_ status: CDJStatus, ip: String) {
        if NetworkInfo.isLocalIPv4(ip), DJLink.looksLikeLegacyFakeClock(
            playerNumber: status.playerNumber,
            pitchPercent: status.pitchPercent,
            trackBPM: status.trackBPM,
            effectiveBPM: status.effectiveBPM,
            trackID: status.trackID
        ) {
            dropDeviceIfPresent(playerNumber: status.playerNumber)
            noteIgnored(
                "fake-\(status.playerNumber)@\(ip)",
                detail: "reloj falso 130 BPM +1.50% player \(status.playerNumber) @ \(ip)"
            )
            return
        }
        // Keepalive (0x06 / claim / hello+status LAN). Un status local no
        // resucita el simulador TEST; un CDJ de LAN sí se adopta si el
        // subtype de 50000 no fue 0x06.
        var target = deviceForPlayer(
            status.playerNumber, ip: ip, model: status.model, firmware: status.firmware
        )
        if target == nil {
            target = adoptLANPlayerFromStatus(status, ip: ip)
        }
        guard let target else { return }
        target.lastSeen = Date()
        if NetworkInfo.isLocalIPv4(ip) { return }

        let statusKey = "\(status.playerNumber)@\(ip)"
        let firstStatus: Bool = bookkeepingQueue.sync {
            if loggedStatusKeys.contains(statusKey) { return false }
            loggedStatusKeys.insert(statusKey)
            return true
        }
        if firstStatus {
            let bpmTxt = status.trackBPM > 0 ? String(format: "%.1f", status.effectiveBPM) : "—"
            log("CDJ player \(status.playerNumber): primer status · pista=\(status.trackLoaded ? "sí" : "no") BPM=\(bpmTxt) on-air=\(status.isOnAir) play=\(status.isPlaying)")
        }

        DispatchQueue.main.async {
            target.pulseActivityIfNeeded()
            if !status.model.isEmpty, target.model != status.model { target.model = status.model }
            if target.firmware != status.firmware { target.firmware = status.firmware }
            if target.isPlaying != status.isPlaying { target.isPlaying = status.isPlaying }
            if target.isMaster != status.isMaster { target.isMaster = status.isMaster }
            if target.isSynced != status.isSynced { target.isSynced = status.isSynced }
            if target.isOnAir != status.isOnAir { target.isOnAir = status.isOnAir }
            if target.playModeLabel != status.playMode.label { target.playModeLabel = status.playMode.label }
            if target.trackLoaded != status.trackLoaded {
                target.trackLoaded = status.trackLoaded
                self.rosterRevision &+= 1
                if !status.trackLoaded {
                    target.trackID = 0
                    target.playhead = 0
                    target.trackLength = 0
                    target.hasPosition = false
                    target.trackBPM = 0
                    target.effectiveBPM = 0
                    target.beatCount = 0
                    target.trackTitle = ""; target.trackArtist = ""; target.trackKey = ""
                    target.trackGenre = ""; target.trackAlbum = ""; target.trackComment = ""
                    target.peaks = []; target.peaksLow = []; target.peaksMid = []; target.peaksHigh = []
                    target.artworkJPEG = Data()
                }
            }
            if target.trackID != status.trackID {
                let newID = status.trackID
                target.trackID = newID
                if newID > 0 {
                    let ip   = target.ip
                    let slot = status.slot.rawValue
                    let player = status.playerNumber
                    let key  = "\(ip):\(slot):\(newID)"
                    // Acceso a caché en bookkeepingQueue para evitar data race
                    self.bookkeepingQueue.async { [weak self, weak target] in
                        guard let self, let target else { return }
                        if let cached = self.metaCache[key] {
                            DispatchQueue.main.async {
                                guard target.trackID == newID else { return }
                                self.applyMeta(cached, to: target)
                            }
                            if cached.artworkId > 0, self.artworkCache[key] == nil {
                                self.fetchArtwork(
                                    ip: ip, slot: slot, artworkId: cached.artworkId,
                                    queryPlayer: self.dbserverQueryPlayers().first ?? 0,
                                    key: key, newID: newID, target: target
                                )
                            }
                        } else {
                            self.netQueue.async { [weak self, weak target] in
                                guard let self, let target else { return }
                                let candidates = self.dbserverQueryPlayers()
                                var accepted: UInt8?
                                var meta: DBServerMeta?
                                for queryAs in candidates {
                                    if let got = DBServerClient.query(
                                        ip: ip, slot: slot, trackID: newID, queryPlayer: queryAs
                                    ), !got.title.isEmpty {
                                        accepted = queryAs
                                        meta = got
                                        break
                                    }
                                    self.log("dbserver: CDJ player \(player) @ \(ip) rechazó título como player \(queryAs) (slot \(slot) trackID \(newID), sin anunciar)")
                                }
                                if let meta, let accepted {
                                    self.log("dbserver: título «\(meta.title)» como player \(accepted) (CDJ \(player) @ \(ip), sin anunciar)")
                                    self.bookkeepingQueue.async {
                                        self.metaCache[key] = meta
                                    }
                                    DispatchQueue.main.async {
                                        guard target.trackID == newID else { return }
                                        self.applyMeta(meta, to: target)
                                    }
                                    if meta.artworkId > 0 {
                                        self.fetchArtwork(
                                            ip: ip, slot: slot, artworkId: meta.artworkId,
                                            queryPlayer: accepted, key: key, newID: newID, target: target
                                        )
                                    }
                                } else {
                                    self.noteMissingTitle(
                                        player: player, trackID: newID, slot: slot,
                                        asQuery: candidates.last
                                    )
                                }
                            }
                        }
                        if let cachedArt = self.artworkCache[key] {
                            DispatchQueue.main.async {
                                guard target.trackID == newID else { return }
                                target.artworkJPEG = cachedArt
                            }
                        }
                        if let cachedWF = self.waveformCache[key] {
                            DispatchQueue.main.async {
                                guard target.trackID == newID else { return }
                                target.peaks = cachedWF.peaks
                                target.peaksLow = cachedWF.peaksLow
                                target.peaksMid = cachedWF.peaksMid
                                target.peaksHigh = cachedWF.peaksHigh
                            }
                        } else {
                            self.netQueue.async { [weak self, weak target] in
                                guard let self, let target else { return }
                                guard let wf = DBServerClient.queryWaveform(
                                    ip: ip, slot: slot, trackID: newID,
                                    queryPlayer: self.dbserverQueryPlayers().first ?? 0
                                ) else { return }
                                self.bookkeepingQueue.async {
                                    self.waveformCache[key] = wf
                                }
                                DispatchQueue.main.async {
                                    guard target.trackID == newID else { return }
                                    target.peaks = wf.peaks
                                    target.peaksLow = wf.peaksLow
                                    target.peaksMid = wf.peaksMid
                                    target.peaksHigh = wf.peaksHigh
                                }
                            }
                        }
                    }
                }
            }
            if target.slotLabel != status.slot.label { target.slotLabel = status.slot.label }
            if abs(target.trackBPM - status.trackBPM) > 0.001 { target.trackBPM = status.trackBPM }
            if abs(target.pitchPercent - status.pitchPercent) > 0.01 { target.pitchPercent = status.pitchPercent }
            if abs(target.faderPitchPercent - status.faderPitchPercent) > 0.01 {
                target.faderPitchPercent = status.faderPitchPercent
            }
            if abs(target.effectiveBPM - status.effectiveBPM) > 0.001 { target.effectiveBPM = status.effectiveBPM }
            if target.beatCount != status.beatCount { target.beatCount = status.beatCount }
            if !target.hasPosition, status.beatCount > 0, status.trackBPM > 0 {
                let estimated = Double(status.beatCount) * 60.0 / status.trackBPM
                if abs(target.playhead - estimated) > 0.05 { target.playhead = estimated }
            }
            if !target.hasStatus { target.hasStatus = true }
        }
    }
}
