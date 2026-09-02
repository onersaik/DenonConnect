// ServiceConnection.swift
// Framing común para los servicios StageLinq (StateMap, BeatInfo): cada
// mensaje va precedido de un uint32 (Big Endian) con su longitud.

import Foundation

public class ServiceConnection {
    let host: String
    let port: UInt16
    let serviceName: String
    let log: (String) -> Void
    var conn: TCPConnection?
    private(set) var stopped = false

    public init(host: String, port: UInt16, serviceName: String, log: @escaping (String) -> Void = { _ in }) {
        self.host = host
        self.port = port
        self.serviceName = serviceName
        self.log = log
    }

    public func stop() {
        stopped = true
        conn?.close()
    }

    /// Conecta y realiza el handshake común a todo servicio: anunciamos quiénes
    /// somos (ServicesAnnouncement + token SoundSwitch + nuestro nombre de
    /// servicio + puerto local, que puede ser 0).
    func connectAndHandshake() throws -> TCPConnection {
        let c = try TCPConnection(host: host, port: port, timeoutSeconds: 8)
        c.setReadTimeout(seconds: 1)

        let w = ByteWriter()
        w.writeUInt32(StageLinq.MessageId.servicesAnnouncement)
        w.writeBytes(StageLinq.soundSwitchToken)
        w.writeNetworkString(serviceName)
        w.writeUInt16(0)
        try c.send(w.data)

        conn = c
        return c
    }

    /// Envía un mensaje con prefijo de longitud (uint32 BE + payload).
    func sendFramed(_ payload: Data) throws {
        guard let c = conn else { throw SocketError.closed }
        let w = ByteWriter()
        w.writeUInt32(UInt32(payload.count))
        w.writeData(payload)
        try c.send(w.data)
    }

    /// Bucle de lectura genérico: acumula bytes, extrae mensajes completos con
    /// prefijo de longitud y los entrega a `handle`. Bloqueante; pensado para
    /// un hilo de fondo.
    func readLoop(handle: @escaping (Data) -> Void) throws {
        guard let c = conn else { throw SocketError.closed }
        var buffer = Data()
        while !stopped {
            guard let chunk = try c.receive(maxBytes: 16384) else { continue }
            buffer.append(chunk)
            buffer = drainFramed(buffer, handle: handle)
        }
    }

    private func drainFramed(_ buffer: Data, handle: (Data) -> Void) -> Data {
        var remaining = buffer
        while remaining.count >= 4 {
            let r = ByteReader(remaining)
            guard let length = try? r.readUInt32() else { return remaining }
            let total = 4 + Int(length)
            guard remaining.count >= total else { return remaining } // mensaje incompleto
            let payload = remaining.subdata(in: remaining.startIndex + 4..<remaining.startIndex + total)
            handle(payload)
            remaining = remaining.suffix(from: remaining.startIndex + total)
        }
        return remaining
    }
}
