// OSCClient.swift
// Cliente OSC mínimo por UDP. OSC es el canal que Resolume expone
// oficialmente para control externo, así que es la vía correcta para
// sincronizarlo con los reproductores.
//
// Formato de un mensaje OSC 1.0:
//   dirección (cadena terminada en 0, rellenada a múltiplo de 4)
//   etiquetas de tipo, empezando por "," (mismo relleno)
//   argumentos en Big Endian

import Foundation

public enum OSCArgument {
    case float(Float)
    case int(Int32)
    case string(String)
}

public final class OSCClient {
    private let host: String
    private let port: UInt16
    private var socket: UDPSocket?

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        self.socket = try? UDPSocket(listenPort: nil)
    }

    public func send(_ address: String, _ arguments: [OSCArgument] = []) {
        guard let socket else { return }
        socket.send(OSCClient.encode(address: address, arguments: arguments), to: host, port: port)
    }

    public func close() {
        socket?.close()
        socket = nil
    }

    public static func encode(address: String, arguments: [OSCArgument]) -> Data {
        var data = Data()
        appendPaddedString(address, to: &data)

        var tags = ","
        for argument in arguments {
            switch argument {
            case .float: tags += "f"
            case .int: tags += "i"
            case .string: tags += "s"
            }
        }
        appendPaddedString(tags, to: &data)

        for argument in arguments {
            switch argument {
            case .float(let value):
                appendBigEndian(value.bitPattern, to: &data)
            case .int(let value):
                appendBigEndian(UInt32(bitPattern: value), to: &data)
            case .string(let value):
                appendPaddedString(value, to: &data)
            }
        }
        return data
    }

    /// Cadena terminada en cero y rellenada hasta múltiplo de 4 bytes.
    private static func appendPaddedString(_ string: String, to data: inout Data) {
        data.append(contentsOf: Array(string.utf8))
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}
