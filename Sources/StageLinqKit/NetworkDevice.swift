// NetworkDevice.swift
// Conexión TCP principal a un dispositivo StageLinq: intercambia anuncios de
// servicios (ServicesAnnouncement), timestamps y el permiso ServicesRequest.
// Una vez conocido el puerto del servicio StateMap/BeatInfo, el llamador abre
// conexiones aparte a esos servicios.

import Foundation

public final class NetworkDeviceConnection {
    private let host: String
    private let port: UInt16
    private var conn: TCPConnection?
    private let log: (String) -> Void

    private var serviceRequestAllowed = false
    private(set) var discoveredServices: [String: UInt16] = [:]
    private var stopped = false

    public init(host: String, port: UInt16, log: @escaping (String) -> Void = { _ in }) {
        self.host = host
        self.port = port
        self.log = log
    }

    public func stop() {
        stopped = true
        conn?.close()
    }

    /// Ejecuta el ciclo de vida completo de la conexión principal (bloqueante,
    /// pensado para correr en un hilo de fondo). Llama a `onServicesUpdate`
    /// cada vez que la lista de servicios anunciados cambia (puede llamarse
    /// varias veces: el dispositivo puede anunciar StateMap y BeatInfo en
    /// mensajes separados) — el llamador debe ser idempotente por servicio.
    public func run(onServicesUpdate: @escaping ([String: UInt16]) -> Void) throws {
        let c = try TCPConnection(host: host, port: port, timeoutSeconds: 8)
        conn = c
        c.setReadTimeout(seconds: 1)

        var buffer = Data()
        var requestSent = false
        var lastServiceCount = 0
        var lastActivity = Date()
        var requestSentAt = Date.distantPast

        while !stopped {
            // El SC6000 puede anunciar HOWDY antes de tener el TCP listo.
            // El reloj arranca con cada byte recibido, no al connect.
            if !requestSent, Date().timeIntervalSince(lastActivity) > 25 {
                throw SocketError.timeout
            }
            if requestSent, discoveredServices.isEmpty, Date().timeIntervalSince(requestSentAt) > 20 {
                throw SocketError.timeout
            }
            guard let chunk = try c.receive(maxBytes: 8192) else {
                continue // timeout de lectura, seguimos esperando
            }
            lastActivity = Date()
            buffer.append(chunk)
            buffer = try drainMainMessages(buffer)

            if serviceRequestAllowed && !requestSent {
                let w = ByteWriter()
                w.writeUInt32(StageLinq.MessageId.servicesRequest)
                w.writeBytes(StageLinq.soundSwitchToken)
                try c.send(w.data)
                requestSent = true
                requestSentAt = Date()
                log("Solicitud de servicios enviada")
            }

            if discoveredServices.count != lastServiceCount {
                lastServiceCount = discoveredServices.count
                onServicesUpdate(discoveredServices)
            }
        }
    }

    /// Procesa mensajes de la conexión principal: uint32 id (BE) + 16 bytes de
    /// token de dispositivo (se ignora) + payload según el id. No usa prefijo
    /// de longitud (a diferencia de los servicios); cada tipo de mensaje sabe
    /// cuánto leer.
    private func drainMainMessages(_ buffer: Data) throws -> Data {
        var remaining = buffer
        while true {
            guard remaining.count >= 20 else { return remaining } // 4 (id) + 16 (token)
            let r = ByteReader(remaining)
            let id = try r.readUInt32()
            _ = try r.readBytes(16) // token de dispositivo, no lo necesitamos

            switch id {
            case StageLinq.MessageId.servicesAnnouncement:
                // Necesitamos al menos 4 bytes más para la longitud del nombre.
                guard r.remaining >= 4 else { return remaining }
                let startBeforeName = r.offset
                guard let name = try? r.readNetworkString() else { return remaining }
                guard r.remaining >= 2 else {
                    // Puerto aún no ha llegado completo; reintentar en la próxima lectura.
                    _ = startBeforeName
                    return remaining
                }
                let port = try r.readUInt16()
                discoveredServices[name] = port
                log("Servicio anunciado: \(name) → puerto \(port)")
                remaining = remaining.suffix(from: remaining.startIndex + r.offset)

            case StageLinq.MessageId.timeStamp:
                guard r.remaining >= 24 else { return remaining } // 16 (token 2) + 8 (uint64)
                _ = try r.readBytes(24)
                remaining = remaining.suffix(from: remaining.startIndex + r.offset)

            case StageLinq.MessageId.servicesRequest:
                serviceRequestAllowed = true
                log("Permiso de ServicesRequest recibido")
                remaining = remaining.suffix(from: remaining.startIndex + r.offset)

            default:
                // Mensaje desconocido: no sabemos su longitud, así que no podemos
                // seguir de forma fiable. Descartamos el resto del buffer.
                log("id de mensaje desconocido \(id); descartando \(remaining.count) bytes")
                return Data()
            }
        }
    }
}
