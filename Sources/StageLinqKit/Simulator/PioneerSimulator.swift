// PioneerSimulator.swift
// Simula un CDJ-3000 en la red: emite presencia (50000), estado detallado
// (50002) y beats con posición absoluta (50001), todo por broadcast UDP.
//
// Misma advertencia que el simulador Denon: comparte interpretación del
// protocolo con el cliente, así que valida la app de punta a punta, no la
// fidelidad al equipo real.

import Foundation

public final class PioneerSimulator {
    private let playerNumber: UInt8
    private let model: String
    private let log: (String) -> Void

    private let queue = DispatchQueue(label: "com.entikrecords.simulator.pioneer", qos: .userInitiated, attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "com.entikrecords.simulator.pioneer.state")
    private var stoppedFlag = false
    private var sockets: [UDPSocket] = []

    // Pista simulada
    private var bpm: Double = 130.0
    private var pitchPercent: Double = 1.5
    private var trackLength: Double = 294
    private var playhead: Double = 0
    private var beatInBar: Int = 1
    private var beatCount: Int = 0

    public init(playerNumber: UInt8 = 2, model: String = "CDJ-3000", log: @escaping (String) -> Void = { _ in }) {
        self.playerNumber = playerNumber
        self.model = model
        self.log = log
    }

    private var stopped: Bool { stateQueue.sync { stoppedFlag } }

    public func start() {
        stateQueue.sync { stoppedFlag = false }
        queue.async { [weak self] in self?.runClock() }
        queue.async { [weak self] in self?.runKeepAlive() }
        queue.async { [weak self] in self?.runStatus() }
        queue.async { [weak self] in self?.runBeats() }
        log("🎚 Simulador Pioneer iniciado como «\(model)» (player \(playerNumber))")
    }

    public func stop() {
        stateQueue.sync { stoppedFlag = true }
        for socket in sockets { socket.close() }
        log("⏹ Simulador Pioneer detenido")
    }

    private func makeSocket() -> UDPSocket? {
        guard let sock = try? UDPSocket(listenPort: nil) else { return nil }
        stateQueue.sync { sockets.append(sock) }
        return sock
    }

    private var effectiveBPM: Double {
        stateQueue.sync { bpm * (1 + pitchPercent / 100.0) }
    }

    // MARK: Reloj

    private func runClock() {
        let tick = 0.05
        while !stopped {
            stateQueue.sync {
                let beatsPerSecond = (bpm * (1 + pitchPercent / 100.0)) / 60.0
                playhead += tick
                if playhead > trackLength { playhead = 0; beatCount = 0 }
                let newBeatCount = Int(playhead * beatsPerSecond)
                if newBeatCount != beatCount {
                    beatCount = newBeatCount
                    beatInBar = (beatCount % 4) + 1
                }
            }
            Thread.sleep(forTimeInterval: tick)
        }
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
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: Estado detallado (50002)

    private func runStatus() {
        guard let sock = makeSocket() else { return }
        while !stopped {
            sock.send(buildStatusPacket(), to: "255.255.255.255", port: DJLink.statusPort)
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Construye un paquete de estado con los mismos offsets que interpreta la app.
    private func buildStatusPacket() -> Data {
        var b = [UInt8](repeating: 0, count: 0x200)
        for (i, v) in DJLink.magic.enumerated() { b[i] = v }
        b[0x0a] = DJLink.PacketType.cdjStatus
        DJLinkCodec.writePaddedString(model, into: &b, at: DJLink.Header.statusModel, length: DJLink.Header.modelLength)
        b[0x1f] = 0x01
        b[0x20] = 0x06                 // variante de paquete (CDJ-3000)
        b[0x21] = playerNumber
        writeUInt16(0x0438, into: &b, at: 0x22)   // bytes restantes: marca CDJ-3000
        b[0x24] = playerNumber
        b[0x25] = 0x00

        writeUInt16(0x0001, into: &b, at: 0x26)   // actividad: reproduciendo
        b[0x28] = playerNumber                    // pista cargada localmente
        b[0x29] = 0x03                            // slot: USB
        b[0x2a] = 0x01                            // pista analizada por rekordbox
        writeUInt32(4021, into: &b, at: 0x2c)     // ID de pista
        writeUInt32(7, into: &b, at: 0x30)        // nº de pista en la lista

        b[0x7b] = 0x03                            // modo de reproducción: play
        DJLinkCodec.writePaddedString("0104", into: &b, at: 0x7c, length: 4)

        // Flags: play (0x40) + master (0x20) + sync (0x10) + on-air (0x08)
        b[0x89] = 0x40 | 0x20 | 0x10 | 0x08
        b[0x8b] = 0xfa                            // segundo indicador de play

        let snapshot = stateQueue.sync { (bpm: bpm, pitch: pitchPercent, beat: beatCount, bar: beatInBar) }
        let pitchRaw = UInt32(max(0, (1.0 + snapshot.pitch / 100.0) * Double(0x100000)))
        writeUInt32(pitchRaw, into: &b, at: 0x8c)          // pitch físico
        writeUInt16(0x8000, into: &b, at: 0x90)            // pista de rekordbox
        writeUInt16(UInt16(snapshot.bpm * 100), into: &b, at: 0x92)
        writeUInt32(pitchRaw, into: &b, at: 0x98)          // pitch efectivo
        writeUInt32(UInt32(max(0, snapshot.beat)), into: &b, at: 0xa0)
        b[0xa6] = UInt8(max(1, min(4, snapshot.bar)))

        return Data(b)
    }

    // MARK: Beats y posición (50001)

    private func runBeats() {
        guard let sock = makeSocket() else { return }
        var lastBeat = -1
        while !stopped {
            let snapshot = stateQueue.sync { (beat: beatCount, bar: beatInBar, head: playhead, len: trackLength) }

            if snapshot.beat != lastBeat {
                lastBeat = snapshot.beat
                sock.send(buildBeatPacket(beatInBar: snapshot.bar), to: "255.255.255.255", port: DJLink.beatPort)
            }
            sock.send(buildPositionPacket(playhead: snapshot.head, length: snapshot.len),
                      to: "255.255.255.255", port: DJLink.beatPort)

            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func buildBeatPacket(beatInBar: Int) -> Data {
        var b = [UInt8](repeating: 0, count: 0x60)
        for (i, v) in DJLink.magic.enumerated() { b[i] = v }
        b[0x0a] = DJLinkBeatPacket.typeBeat
        DJLinkCodec.writePaddedString(model, into: &b, at: DJLink.Header.statusModel, length: DJLink.Header.modelLength)
        writeUInt16(0x0100, into: &b, at: 0x1f)
        b[0x21] = playerNumber
        b[0x23] = 0x3c

        let snapshot = stateQueue.sync { (bpm: bpm, pitch: pitchPercent) }
        let pitchRaw = UInt32(max(0, (1.0 + snapshot.pitch / 100.0) * Double(0x100000)))
        writeUInt32(pitchRaw, into: &b, at: 0x54)
        writeUInt16(UInt16(snapshot.bpm * 100), into: &b, at: 0x5a)
        b[0x5c] = UInt8(max(1, min(4, beatInBar)))
        b[0x5f] = playerNumber
        return Data(b)
    }

    private func buildPositionPacket(playhead: Double, length: Double) -> Data {
        var b = [UInt8](repeating: 0, count: 0x3c)
        for (i, v) in DJLink.magic.enumerated() { b[i] = v }
        b[0x0a] = DJLinkBeatPacket.typeAbsolutePosition
        DJLinkCodec.writePaddedString(model, into: &b, at: DJLink.Header.statusModel, length: DJLink.Header.modelLength)
        writeUInt16(0x0100, into: &b, at: 0x1f)
        b[0x21] = playerNumber

        writeUInt32(UInt32(max(0, length)), into: &b, at: 0x24)
        writeUInt32(UInt32(max(0, playhead * 1000)), into: &b, at: 0x28)
        writeUInt32(UInt32(max(0, effectiveBPM * 10)), into: &b, at: 0x38)
        return Data(b)
    }

    // MARK: Utilidades

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
