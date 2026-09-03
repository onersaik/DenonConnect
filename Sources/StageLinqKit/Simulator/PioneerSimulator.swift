// PioneerSimulator.swift
// Simula un CDJ-3000 en la red: emite presencia (50000), estado detallado
// (50002) y beats con posición absoluta (50001), todo por broadcast UDP.
//
// Sin stateProvider (y sin standaloneMode) el reproductor se anuncia en idle:
// sin pista, sin play, sin reloj inventado. El estado real lo inyecta
// STAGE CONNECT TEST igual que DenonSimulator.

import Foundation

public final class PioneerSimulator {
    private let playerNumber: UInt8
    private let model: String
    private let log: (String) -> Void

    private let queue = DispatchQueue(label: "com.entikrecords.simulator.pioneer", qos: .userInitiated, attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "com.entikrecords.simulator.pioneer.state")
    private var stoppedFlag = false
    private var sockets: [UDPSocket] = []

    /// Proveedor de estado externo (mismos decks que Denon). Si está asignado,
    /// el CDJ refleja el deck 0 (A) de TEST. Sin pista → idle real.
    public var stateProvider: (() -> [SimDeckState])?

    /// Solo para pruebas aisladas. Por defecto false: no se inventa pista.
    public var standaloneMode: Bool = false

    private var bpm: Double = 0
    private var pitchPercent: Double = 0
    private var trackLength: Double = 0
    private var playhead: Double = 0
    private var beatInBar: Int = 0
    private var beatCount: Int = 0
    private var playing: Bool = false
    private var loaded: Bool = false
    private var trackID: UInt32 = 0

    public init(playerNumber: UInt8 = 2, model: String = "CDJ-3000", log: @escaping (String) -> Void = { _ in }) {
        self.playerNumber = playerNumber
        self.model = model
        self.log = log
    }

    private var stopped: Bool { stateQueue.sync { stoppedFlag } }

    public func start() {
        stateQueue.sync { stoppedFlag = false }
        queue.async { [weak self] in self?.runKeepAlive() }
        queue.async { [weak self] in self?.runStatus() }
        queue.async { [weak self] in self?.runBeats() }
        log("[Pioneer] Activo como «\(model)» (player \(playerNumber))")
    }

    public func stop() {
        stateQueue.sync { stoppedFlag = true }
        for socket in sockets { socket.close() }
        log("[Pioneer] Detenido")
    }

    private func makeSocket() -> UDPSocket? {
        guard let sock = try? UDPSocket(listenPort: nil) else { return nil }
        stateQueue.sync { sockets.append(sock) }
        return sock
    }

    // MARK: Estado vivo (TEST o idle)

    private struct Live {
        var loaded: Bool
        var playing: Bool
        var bpm: Double
        var pitch: Double
        var playhead: Double
        var length: Double
        var beatCount: Int
        var beatInBar: Int
        var trackID: UInt32
        var isMaster: Bool
        var isSync: Bool
    }

    private func liveState() -> Live {
        if let provider = stateProvider {
            let s = provider().first { !$0.title.isEmpty || $0.duration > 0 } ?? SimDeckState()
            let loaded = !s.title.isEmpty || s.duration > 0
            let bpm = loaded ? MusicalClock.bpm(s.bpm) : 0
            let dur = loaded && s.duration > 0 ? s.duration : 0
            let pos = loaded ? max(0, s.positionSeconds) : 0
            let beatsPerSec = bpm > 0 ? bpm / 60.0 : 0
            let beatCount = Int(pos * beatsPerSec)
            return Live(
                loaded: loaded,
                playing: loaded && s.isPlaying,
                bpm: bpm,
                pitch: s.pitchPercent,
                playhead: pos,
                length: dur,
                beatCount: beatCount,
                beatInBar: loaded && beatCount >= 0 ? (beatCount % 4) + 1 : 0,
                trackID: loaded ? Self.hashTrackID(s.title) : 0,
                isMaster: loaded && s.isMaster,
                isSync: loaded && s.isSync
            )
        }
        if standaloneMode {
            return stateQueue.sync {
                Live(loaded: loaded, playing: playing, bpm: bpm, pitch: pitchPercent,
                     playhead: playhead, length: trackLength, beatCount: beatCount,
                     beatInBar: beatInBar, trackID: trackID, isMaster: playing, isSync: false)
            }
        }
        return Live(loaded: false, playing: false, bpm: 0, pitch: 0, playhead: 0,
                    length: 0, beatCount: 0, beatInBar: 0, trackID: 0, isMaster: false, isSync: false)
    }

    private static func hashTrackID(_ title: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in title.utf8 {
            h ^= UInt32(b)
            h &*= 16777619
        }
        return h == 0 ? 1 : h
    }

    // MARK: Presencia (50000)

    private func runKeepAlive() {
        guard let sock = makeSocket() else { return }
        let ip = NetworkInfo.localIPv4Bytes()
        let packet = DJLinkKeepAlive.buildVirtualCDJ(
            playerNumber: playerNumber,
            model: model,
            ip: ip,
            mac: [0x02, 0x00, 0x00, 0x00, 0x00, playerNumber]
        )
        while !stopped {
            sock.send(packet, to: "255.255.255.255", port: DJLink.keepAlivePort)
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: Estado detallado (50002)

    private func runStatus() {
        guard let sock = makeSocket() else { return }
        while !stopped {
            let live = liveState()
            if live.loaded {
                sock.send(buildStatusPacket(live), to: "255.255.255.255", port: DJLink.statusPort)
                Thread.sleep(forTimeInterval: 0.2)
            } else {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private func buildStatusPacket(_ live: Live) -> Data {
        var b = [UInt8](repeating: 0, count: 0x200)
        for (i, v) in DJLink.magic.enumerated() { b[i] = v }
        b[0x0a] = DJLink.PacketType.cdjStatus
        DJLinkCodec.writePaddedString(model, into: &b, at: DJLink.Header.statusModel, length: DJLink.Header.modelLength)
        b[0x1f] = 0x01
        b[0x20] = 0x06
        b[0x21] = playerNumber
        writeUInt16(0x0438, into: &b, at: 0x22)
        b[0x24] = playerNumber
        b[0x25] = 0x00

        if live.loaded {
            writeUInt16(live.playing ? 0x0001 : 0x0000, into: &b, at: 0x26)
            b[0x28] = playerNumber
            b[0x29] = 0x03
            b[0x2a] = 0x01
            writeUInt32(live.trackID, into: &b, at: 0x2c)
            writeUInt32(1, into: &b, at: 0x30)
            b[0x7b] = live.playing ? 0x03 : 0x05
            DJLinkCodec.writePaddedString(DJLink.simulatorFirmware, into: &b, at: 0x7c, length: 4)
            var flags: UInt8 = 0
            if live.playing { flags |= 0x40 }
            if live.isMaster { flags |= 0x20 }
            if live.isSync { flags |= 0x10 }
            b[0x89] = flags
            b[0x8b] = live.playing ? 0xfa : 0x00
            let pitchRaw = Self.pitchRaw(live.pitch)
            writeUInt32(pitchRaw, into: &b, at: 0x8c)
            writeUInt16(0x8000, into: &b, at: 0x90)
            writeUInt16(UInt16(max(0, live.bpm * 100)), into: &b, at: 0x92)
            writeUInt32(pitchRaw, into: &b, at: 0x98)
            writeUInt32(UInt32(max(0, live.beatCount)), into: &b, at: 0xa0)
            b[0xa6] = UInt8(max(0, min(4, live.beatInBar)))
        } else {
            writeUInt16(0x0000, into: &b, at: 0x26)
            b[0x28] = 0x00
            b[0x29] = 0x00
            b[0x2a] = 0x00
            writeUInt32(0, into: &b, at: 0x2c)
            writeUInt32(0, into: &b, at: 0x30)
            b[0x7b] = 0x00
            DJLinkCodec.writePaddedString(DJLink.simulatorFirmware, into: &b, at: 0x7c, length: 4)
            b[0x89] = 0x00
            b[0x8b] = 0x00
            writeUInt32(UInt32(0x100000), into: &b, at: 0x8c)
            writeUInt16(0x0000, into: &b, at: 0x90)
            writeUInt16(0xffff, into: &b, at: 0x92)
            writeUInt32(UInt32(0x100000), into: &b, at: 0x98)
            writeUInt32(0, into: &b, at: 0xa0)
            b[0xa6] = 0
        }

        return Data(b)
    }

    // MARK: Beats y posición (50001)

    private func runBeats() {
        guard let sock = makeSocket() else { return }
        var lastBar = -1
        while !stopped {
            let live = liveState()
            if live.loaded {
                if live.playing, live.beatInBar != lastBar, live.beatInBar > 0 {
                    lastBar = live.beatInBar
                    sock.send(buildBeatPacket(beatInBar: live.beatInBar, bpm: live.bpm, pitch: live.pitch),
                              to: "255.255.255.255", port: DJLink.beatPort)
                }
                sock.send(buildPositionPacket(playhead: live.playhead, length: live.length, bpm: live.bpm),
                          to: "255.255.255.255", port: DJLink.beatPort)
            } else {
                lastBar = -1
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func buildBeatPacket(beatInBar: Int, bpm: Double, pitch: Double = 0) -> Data {
        var b = [UInt8](repeating: 0, count: 0x60)
        for (i, v) in DJLink.magic.enumerated() { b[i] = v }
        b[0x0a] = DJLinkBeatPacket.typeBeat
        DJLinkCodec.writePaddedString(model, into: &b, at: DJLink.Header.statusModel, length: DJLink.Header.modelLength)
        writeUInt16(0x0100, into: &b, at: 0x1f)
        b[0x21] = playerNumber
        b[0x23] = 0x3c

        let pitchRaw = Self.pitchRaw(pitch)
        writeUInt32(pitchRaw, into: &b, at: 0x54)
        writeUInt16(UInt16(max(0, bpm * 100)), into: &b, at: 0x5a)
        b[0x5c] = UInt8(max(1, min(4, beatInBar)))
        b[0x5f] = playerNumber
        return Data(b)
    }

    private func buildPositionPacket(playhead: Double, length: Double, bpm: Double) -> Data {
        var b = [UInt8](repeating: 0, count: 0x3c)
        for (i, v) in DJLink.magic.enumerated() { b[i] = v }
        b[0x0a] = DJLinkBeatPacket.typeAbsolutePosition
        DJLinkCodec.writePaddedString(model, into: &b, at: DJLink.Header.statusModel, length: DJLink.Header.modelLength)
        writeUInt16(0x0100, into: &b, at: 0x1f)
        b[0x21] = playerNumber

        writeUInt32(length > 0 ? UInt32(max(1, length.rounded())) : 0, into: &b, at: 0x24)
        writeUInt32(UInt32(max(0, playhead * 1000)), into: &b, at: 0x28)
        writeUInt32(UInt32(max(0, bpm * 10)), into: &b, at: 0x38)
        return Data(b)
    }

    // MARK: Utilidades

    /// 0x100000 = 0 %. pitchPercent +6 → ratio 1.06.
    private static func pitchRaw(_ percent: Double) -> UInt32 {
        let ratio = max(0.5, min(2.0, 1.0 + percent / 100.0))
        return UInt32((ratio * Double(0x100000)).rounded())
    }

    private func writeUInt16(_ v: UInt16, into b: inout [UInt8], at i: Int) {
        guard i + 1 < b.count else { return }
        b[i] = UInt8((v >> 8) & 0xff)
        b[i + 1] = UInt8(v & 0xff)
    }

    private func writeUInt32(_ v: UInt32, into b: inout [UInt8], at i: Int) {
        guard i + 3 < b.count else { return }
        b[i] = UInt8((v >> 24) & 0xff)
        b[i + 1] = UInt8((v >> 16) & 0xff)
        b[i + 2] = UInt8((v >> 8) & 0xff)
        b[i + 3] = UInt8(v & 0xff)
    }
}
