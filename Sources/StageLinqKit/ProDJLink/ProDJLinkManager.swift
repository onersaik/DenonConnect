// ProDJLinkManager.swift
// Descubrimiento y estado en vivo de reproductores Pioneer/AlphaTheta
// (CDJ-3000, CDJ-2000NXS2, XDJ, DJM) por Pro DJ Link.
//
// Funciona en tres hilos de fondo:
//   1. Escucha el puerto 50000 → descubre qué reproductores hay en la red.
//   2. Se anuncia como "CDJ virtual" cada 1,5 s → sin esto los CDJ NO envían
//      estado detallado a nadie.
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
    @Published public var slotLabel: String = "—"

    @Published public var trackBPM: Double = 0
    @Published public var pitchPercent: Double = 0
    @Published public var effectiveBPM: Double = 0

    @Published public var beatCount: Int = 0
    @Published public var beatInBar: Int = 0
    @Published public var beatPulse: Bool = false

    // Solo CDJ-3000: posición exacta de reproducción (puerto 50001).
    @Published public var trackLength: Double = 0   // segundos
    @Published public var playhead: Double = 0      // segundos
    @Published public var hasPosition: Bool = false

    public var remaining: Double { max(trackLength - playhead, 0) }
    public var progress: Double {
        guard trackLength > 0 else { return 0 }
        return min(max(playhead / trackLength, 0), 1)
    }

    /// CDJ virtual de STAGE CONNECT (player 7 / modelo propio). Nunca debe pintarse.
    public var isOwnVirtualCDJ: Bool {
        DJLink.isVirtualCDJ(playerNumber: playerNumber, model: model)
    }

    /// PioneerSimulator de STAGE CONNECT TEST en este Mac (misma IP, no player 7).
    public var isLocalTestSimulator: Bool {
        NetworkInfo.isLocalIPv4(ip) && !isOwnVirtualCDJ
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
    /// No @Published: actualizarlo en cada paquete reventaba SwiftUI.
    public var lastSeen: Date = Date()
    public var positionReceivedAt: Date = Date()  // No @Published — solo para interpolación

    public init(playerNumber: Int, model: String, ip: String) {
        self.id = "cdj-\(playerNumber)-\(ip)"
        self.playerNumber = playerNumber
        self.model = model
        self.ip = ip
    }
}

public final class ProDJLinkManager: ObservableObject {
    @Published public private(set) var devices: [ProDJLinkDevice] = []
    @Published public private(set) var logLines: [String] = []
    @Published public private(set) var rosterRevision: UInt64 = 0

    private var devicesByKey: [String: ProDJLinkDevice] = [:]
    private let bookkeepingQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.prodjlink.book")
    private let netQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.prodjlink.net", qos: .userInitiated, attributes: .concurrent)

    private var keepAliveSocket: UDPSocket?
    private var statusSocket: UDPSocket?
    private var beatSocket: UDPSocket?
    private var stoppedFlag = false
    private var loggedIgnoreKeys: Set<String> = []
    private var metaCache: [String: DBServerMeta] = [:]

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
        bookkeepingQueue.sync { stoppedFlag = false }
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
            let socket = try UDPSocket(listenPort: DJLink.keepAlivePort)
            keepAliveSocket = socket
            log(" Pro DJ Link: escuchando presencia en UDP :\(DJLink.keepAlivePort)")

            while !stopped {
                guard let (data, fromIP) = socket.receive() else { continue }
                guard let announce = DJLinkKeepAlive.parse(data) else { continue }
                handleAnnounce(announce, fromIP: fromIP)
            }
            socket.close()
        } catch {
            log(" Pro DJ Link: no se pudo escuchar en UDP \(DJLink.keepAlivePort): \(error). ¿rekordbox abierto?")
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
        if DJLink.isVirtualCDJ(playerNumber: announce.playerNumber, model: announce.model) {
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
        let key = String(announce.playerNumber)
        let existing: ProDJLinkDevice? = bookkeepingQueue.sync { devicesByKey[key] }

        if let device = existing {
            device.lastSeen = Date()
            DispatchQueue.main.async {
                if device.ip != ip { device.ip = ip }
                if !announce.model.isEmpty, device.model != announce.model { device.model = announce.model }
            }
            return
        }

        let device = ProDJLinkDevice(playerNumber: announce.playerNumber, model: announce.model, ip: ip)
        bookkeepingQueue.sync { devicesByKey[key] = device }
        DispatchQueue.main.async {
            if !self.devices.contains(where: { $0.playerNumber == device.playerNumber }) {
                self.devices.append(device)
                self.devices.sort { $0.playerNumber < $1.playerNumber }
            }
        }
        log(" CDJ detectado: \(announce.model) · reproductor \(announce.playerNumber) @ \(ip)")
    }

    // MARK: - 2. Anuncio como CDJ virtual (imprescindible)

    private func runVirtualCDJAnnounce() {
        guard let sock = try? UDPSocket(listenPort: nil) else {
            log("[AVISO] Pro DJ Link: no se pudo crear el socket de anuncio")
            return
        }
        let ipBytes = NetworkInfo.localIPv4Bytes()
        log(" Pro DJ Link: anunciándonos como reproductor virtual \(DJLink.virtualPlayerNumber) desde \(NetworkInfo.describe(ipBytes))")

        let packet = DJLinkKeepAlive.buildVirtualCDJ(
            playerNumber: DJLink.virtualPlayerNumber,
            model: DJLink.virtualModelName,
            ip: ipBytes,
            mac: [0, 0, 0, 0, 0, 0]
        )

        while !stopped {
            sock.send(packet, to: "255.255.255.255", port: DJLink.keepAlivePort)
            Thread.sleep(forTimeInterval: 1.5)
        }
        sock.close()
    }

    // MARK: - 3. Estado detallado (puerto 50002)

    private func runStatusListener() {
        do {
            let socket = try UDPSocket(listenPort: DJLink.statusPort)
            statusSocket = socket
            log(" Pro DJ Link: escuchando estado en UDP :\(DJLink.statusPort)")

            while !stopped {
                guard let (data, ip) = socket.receive() else { continue }
                guard let status = CDJStatus.parse(data) else { continue }
                applyStatus(status, ip: ip)
            }
            socket.close()
        } catch {
            log(" Pro DJ Link: no se pudo escuchar en UDP \(DJLink.statusPort): \(error)")
        }
    }

    // MARK: - 4. Beats y posición exacta (puerto 50001)

    private func runBeatListener() {
        do {
            let socket = try UDPSocket(listenPort: DJLink.beatPort)
            beatSocket = socket
            log(" Pro DJ Link: escuchando beats en UDP :\(DJLink.beatPort)")

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
            log(" Pro DJ Link: no se pudo escuchar en UDP \(DJLink.beatPort): \(error)")
        }
    }

    // MARK: - 5. Caducar CDJ que ya no anuncian (Pioneer TEST al apagar)

    private func runStalePrune() {
        while !stopped {
            Thread.sleep(forTimeInterval: 0.5)
            let now = Date()
            let stale: [ProDJLinkDevice] = bookkeepingQueue.sync {
                devicesByKey.values.filter { now.timeIntervalSince($0.lastSeen) > 5.0 }
            }
            guard !stale.isEmpty else { continue }
            let keys = stale.map { String($0.playerNumber) }
            bookkeepingQueue.sync {
                for key in keys { devicesByKey.removeValue(forKey: key) }
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

    /// Un CDJ se identifica por número de reproductor (1–6). No se crean
    /// dispositivos a partir de paquetes de estado: si el keepalive paró,
    /// un status rezagado no debe resucitar un fantasma.
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
            if target.beatInBar != beat.beatInBar {
                target.beatInBar = beat.beatInBar
                target.beatPulse.toggle()
            }
        }
    }

    private func applyPosition(_ pos: DJLinkAbsolutePosition, ip: String) {
        guard let target = deviceForPlayer(pos.playerNumber, ip: ip) else { return }
        if DJLink.looksLikeLegacyFakeClock(
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
        let recvAt = Date()
        DispatchQueue.main.async {
            if abs(target.trackLength - pos.trackLength) > 0.01 { target.trackLength = pos.trackLength }
            if abs(target.playhead - pos.playhead) > 0.001 {
                target.playhead = pos.playhead
                target.positionReceivedAt = recvAt
            }
            if !target.hasPosition { target.hasPosition = true }
        }
    }

    private func applyStatus(_ status: CDJStatus, ip: String) {
        if DJLink.looksLikeLegacyFakeClock(
            playerNumber: status.playerNumber,
            pitchPercent: status.pitchPercent,
            trackBPM: status.trackBPM,
            effectiveBPM: status.effectiveBPM,
            trackID: status.trackID
        ) {
            dropDeviceIfPresent(playerNumber: status.playerNumber)
            noteIgnored(
                "fake-\(status.playerNumber)@\(ip)",
                detail: "reloj falso 130 BPM +1.50% player \(status.playerNumber)"
            )
            return
        }
        // Solo se actualiza un CDJ ya descubierto por keepalive. Un status
        // suelto (simulador parado, paquete en vuelo) no crea filas fantasma.
        guard let target = deviceForPlayer(
            status.playerNumber, ip: ip, model: status.model, firmware: status.firmware
        ) else { return }
        target.lastSeen = Date()
        if NetworkInfo.isLocalIPv4(ip) { return }

        DispatchQueue.main.async {
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
                }
            }
            if target.trackID != status.trackID {
                let newID = status.trackID
                target.trackID = newID
                if newID > 0 {
                    let ip   = target.ip
                    let slot = status.slot.rawValue
                    let key  = "\(ip):\(slot):\(newID)"
                    // Acceso a caché en bookkeepingQueue para evitar data race
                    self.bookkeepingQueue.async { [weak self, weak target] in
                        guard let self, let target else { return }
                        if let cached = self.metaCache[key] {
                            DispatchQueue.main.async {
                                guard target.trackID == newID else { return }
                                target.trackTitle  = cached.title
                                target.trackArtist = cached.artist
                                target.trackKey    = cached.key
                            }
                        } else {
                            self.netQueue.async { [weak self, weak target] in
                                guard let self, let target else { return }
                                guard let meta = DBServerClient.query(
                                    ip: ip, slot: slot, trackID: newID) else { return }
                                self.bookkeepingQueue.async {
                                    self.metaCache[key] = meta
                                }
                                DispatchQueue.main.async {
                                    guard target.trackID == newID else { return }
                                    target.trackTitle  = meta.title
                                    target.trackArtist = meta.artist
                                    target.trackKey    = meta.key
                                }
                            }
                        }
                    }
                }
            }
            if target.slotLabel != status.slot.label { target.slotLabel = status.slot.label }
            if abs(target.trackBPM - status.trackBPM) > 0.001 { target.trackBPM = status.trackBPM }
            if abs(target.pitchPercent - status.pitchPercent) > 0.01 { target.pitchPercent = status.pitchPercent }
            if abs(target.effectiveBPM - status.effectiveBPM) > 0.001 { target.effectiveBPM = status.effectiveBPM }
            if target.beatCount != status.beatCount { target.beatCount = status.beatCount }
            if !target.hasStatus { target.hasStatus = true }
        }
    }
}
