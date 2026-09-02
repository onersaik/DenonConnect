// StateMapService.swift
// Servicio StateMap: nos suscribimos a las rutas de estado y recibimos
// actualizaciones como JSON embebido en mensajes binarios con marcador "smaa".

import Foundation

public final class StateMapService: ServiceConnection {
    public init(host: String, port: UInt16, log: @escaping (String) -> Void = { _ in }) {
        super.init(host: host, port: port, serviceName: "StateMap", log: log)
    }

    /// Conecta, se suscribe a todas las rutas conocidas y entra en el bucle de
    /// lectura. Bloqueante: llamar desde un hilo de fondo.
    public func run(onUpdate: @escaping (_ path: String, _ value: StateValue) -> Void) throws {
        _ = try connectAndHandshake()
        log("StateMap conectado, suscribiendo \(StatePaths.allPaths().count) rutas")

        for path in StatePaths.allPaths() {
            let w = ByteWriter()
            w.writeFixedString(StageLinq.StateMapMarker.magic)
            w.writeUInt32(StageLinq.StateMapMarker.typeInterval)
            w.writeNetworkString(path)
            w.writeInt32(0) // intervalo 0 = notificar en cada cambio
            try? sendFramed(w.data)
        }

        try readLoop { [weak self] payload in
            self?.handlePayload(payload, onUpdate: onUpdate)
        }
    }

    private func handlePayload(_ payload: Data, onUpdate: (_ path: String, _ value: StateValue) -> Void) {
        guard payload.count >= 8 else { return }
        let magicBytes = payload.prefix(4)
        guard String(decoding: magicBytes, as: UTF8.self) == StageLinq.StateMapMarker.magic else { return }

        let r = ByteReader(payload.suffix(from: payload.startIndex + 4))
        guard let msgType = try? r.readUInt32() else { return }

        switch msgType {
        case StageLinq.StateMapMarker.typeJSON:
            guard let name = try? r.readNetworkString(),
                  let jsonStr = try? r.readNetworkString(),
                  let value = StateValueCodec.decode(jsonStr) else { return }
            onUpdate(name, value)
        case StageLinq.StateMapMarker.typeInterval:
            break // confirmación de suscripción, no requiere acción
        default:
            break
        }
    }
}
