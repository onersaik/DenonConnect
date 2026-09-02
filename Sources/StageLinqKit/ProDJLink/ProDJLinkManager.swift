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
    @Published public var slotLabel: String = "—"

    @Published public var trackBPM: Double = 0
    @Published public var pitchPercent: Double = 0
    @Published public var effectiveBPM: Double = 0

    @Published public var beatCount: Int = 0
    @Published public var beatInBar: Int = 0
    @Published public var beatPulse: Bool = false

    @Published public var hasStatus: Bool = false
    @Published public var lastSeen: Date = Date()

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

    private var devicesByKey: [String: ProDJLinkDevice] = [:]
    private let bookkeepingQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.prodjlink.book")
    private let netQueue = DispatchQueue(label: "com.entikrecords.sc6000connect.prodjlink.net", qos: .userInitiated, attributes: .concurrent)

    private var keepAliveSocket: UDPSocket?
    private var statusSocket: UDPSocket?
    private var stoppedFlag = false

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
        netQueue.async { [weak self] in self?.runVirtualCDJAnnounce() }
    }

    public func stop() {
        bookkeepingQueue.sync { stoppedFlag = true }
        keepAliveSocket?.close()
        statusSocket?.close()
    }

    // MARK: - 1. Descubrimiento (puerto 50000)

    private func runKeepAliveListener() {
        do {
            let socket = try UDPSocket(listenPort: DJLink.keepAlivePort)
            keepAliveSocket = socket
            log("👂 Pro DJ Link: escuchando presencia en UDP :\(DJLink.keepAlivePort)")

            while !stopped {
                guard let (data, _) = socket.receive() else { continue }
                guard let announce = DJLinkKeepAlive.parse(data) else { continue }
                // Ignoramos nuestro propio anuncio.
                guard announce.playerNumber != Int(DJLink.virtualPlayerNumber) else { continue }
                handleAnnounce(announce)
            }
            socket.close()
        } catch {
            log("❌ Pro DJ Link: no se pudo escuchar en UDP \(DJLink.keepAlivePort): \(error). ¿rekordbox abierto?")
        }
    }

    private func handleAnnounce(_ announce: DJLinkKeepAlive) {
        let key = "\(announce.playerNumber)@\(announce.ip)"
        let existing: ProDJLinkDevice? = bookkeepingQueue.sync { devicesByKey[key] }

        if let device = existing {
            DispatchQueue.main.async { device.lastSeen = Date() }
            return
        }

        let device = ProDJLinkDevice(playerNumber: announce.playerNumber, model: announce.model, ip: announce.ip)
        bookkeepingQueue.sync { devicesByKey[key] = device }
        DispatchQueue.main.async {
            self.devices.append(device)
            self.devices.sort { $0.playerNumber < $1.playerNumber }
        }
        log("🎚 CDJ detectado: \(announce.model) · reproductor \(announce.playerNumber) @ \(announce.ip)")
    }

    // MARK: - 2. Anuncio como CDJ virtual (imprescindible)

    private func runVirtualCDJAnnounce() {
        guard let sock = try? UDPSocket(listenPort: nil) else {
            log("⚠️ Pro DJ Link: no se pudo crear el socket de anuncio")
            return
        }
        let ipBytes = NetworkInfo.localIPv4Bytes()
        log("📡 Pro DJ Link: anunciándonos como reproductor virtual \(DJLink.virtualPlayerNumber) desde \(NetworkInfo.describe(ipBytes))")

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
            log("📊 Pro DJ Link: escuchando estado en UDP :\(DJLink.statusPort)")

            while !stopped {
                guard let (data, ip) = socket.receive() else { continue }
                guard let status = CDJStatus.parse(data) else { continue }
                applyStatus(status, ip: ip)
            }
            socket.close()
        } catch {
            log("❌ Pro DJ Link: no se pudo escuchar en UDP \(DJLink.statusPort): \(error)")
        }
    }

    private func applyStatus(_ status: CDJStatus, ip: String) {
        let key = "\(status.playerNumber)@\(ip)"
        var device: ProDJLinkDevice? = bookkeepingQueue.sync { devicesByKey[key] }

        if device == nil {
            // Un CDJ puede enviarnos estado antes de que hayamos visto su
            // paquete de presencia; lo damos de alta igualmente.
            let created = ProDJLinkDevice(playerNumber: status.playerNumber, model: status.model, ip: ip)
            bookkeepingQueue.sync { devicesByKey[key] = created }
            DispatchQueue.main.async {
                self.devices.append(created)
                self.devices.sort { $0.playerNumber < $1.playerNumber }
            }
            log("🎚 CDJ con estado activo: \(status.model) · reproductor \(status.playerNumber) @ \(ip)")
            device = created
        }

        guard let target = device else { return }

        DispatchQueue.main.async {
            let crossedBeat = target.beatCount != status.beatCount

            target.model = status.model.isEmpty ? target.model : status.model
            target.firmware = status.firmware
            target.isPlaying = status.isPlaying
            target.isMaster = status.isMaster
            target.isSynced = status.isSynced
            target.isOnAir = status.isOnAir
            target.playModeLabel = status.playMode.label
            target.trackLoaded = status.trackLoaded
            target.trackID = status.trackID
            target.slotLabel = status.slot.label
            target.trackBPM = status.trackBPM
            target.pitchPercent = status.pitchPercent
            target.effectiveBPM = status.effectiveBPM
            target.beatCount = status.beatCount
            target.beatInBar = status.beatInBar
            target.hasStatus = true
            target.lastSeen = Date()

            if crossedBeat && status.isPlaying {
                target.beatPulse.toggle()
            }
        }
    }
}
