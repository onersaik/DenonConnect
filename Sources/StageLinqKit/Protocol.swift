// Protocol.swift
// Constantes y framing del protocolo StageLinq, verificado contra la
// implementación de referencia https://github.com/chrisle/StageLinq

import Foundation

public enum StageLinq {
    public static let listenPort: UInt16 = 51337
    public static let magic = "airD"
    public static let actionLogin = "DISCOVERER_HOWDY_"
    public static let actionLogout = "DISCOVERER_EXIT_"

    /// Token fijo "SoundSwitch": identifica a los clientes tipo "Now Playing".
    /// Los SC6000 lo reconocen como un cliente legítimo.
    public static let soundSwitchToken: [UInt8] = [
        82, 253, 252, 7, 33, 130, 101, 79, 22, 63, 95, 15, 154, 98, 29, 114,
    ]

    /// Identidad con la que este cliente se anuncia en la red.
    public static let identityName = "nowplaying"
    public static let identityVersion = "2.2.0"
    public static let identitySource = "np2"

    // IDs de mensaje de la conexión principal (NetworkDevice)
    public enum MessageId {
        public static let servicesAnnouncement: UInt32 = 0x0
        public static let timeStamp: UInt32 = 0x1
        public static let servicesRequest: UInt32 = 0x2
    }

    // Marcadores del servicio StateMap
    public enum StateMapMarker {
        public static let magic = "smaa"
        public static let typeJSON: UInt32 = 0x00000000
        public static let typeInterval: UInt32 = 0x000007d2
    }
}

public struct DiscoveryInfo {
    public var token: [UInt8]
    public var source: String
    public var action: String
    public var name: String
    public var version: String
    public var port: UInt16
    public var address: String = ""
}

public enum DiscoveryCodec {
    /// Construye el paquete de anuncio: "airD" + token[16] + netstr(source) +
    /// netstr(action) + netstr(nombre) + netstr(versión) + uint16(puerto).
    public static func build(token: [UInt8], source: String, action: String, name: String, version: String, port: UInt16) -> Data {
        let w = ByteWriter()
        w.writeFixedString(StageLinq.magic)
        w.writeBytes(token)
        w.writeNetworkString(source)
        w.writeNetworkString(action)
        w.writeNetworkString(name)
        w.writeNetworkString(version)
        w.writeUInt16(port)
        return w.data
    }

    public static func parse(_ data: Data) -> DiscoveryInfo? {
        guard data.count >= 4 else { return nil }
        let magicBytes = data.prefix(4)
        guard String(decoding: magicBytes, as: UTF8.self) == StageLinq.magic else { return nil }

        let r = ByteReader(data.suffix(from: data.startIndex + 4))
        do {
            let token = try r.readBytes(16)
            let source = try r.readNetworkString()
            let action = try r.readNetworkString()
            let name = try r.readNetworkString()
            let version = try r.readNetworkString()
            let port = try r.readUInt16()
            return DiscoveryInfo(token: token, source: source, action: action, name: name, version: version, port: port)
        } catch {
            return nil
        }
    }
}
