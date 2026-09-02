// NetworkInfo.swift
// Datos de la interfaz de red local. Necesarios porque el paquete de presencia
// Pro DJ Link debe incluir nuestra propia IP para que los CDJ sepan a dónde
// enviarnos el estado detallado.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum NetworkInfo {
    /// IPv4 de la primera interfaz activa que no sea loopback, como 4 bytes.
    /// Prioriza interfaces "en" (Ethernet/Wi-Fi en macOS) sobre el resto.
    public static func localIPv4Bytes() -> [UInt8] {
        var preferred: [UInt8]?
        var fallback: [UInt8]?

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return [0, 0, 0, 0] }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor = ifaddrPtr
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            guard let addr = interface.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let raw = sin.sin_addr.s_addr // orden de red (big endian)
            let bytes: [UInt8] = [
                UInt8(raw & 0xff),
                UInt8((raw >> 8) & 0xff),
                UInt8((raw >> 16) & 0xff),
                UInt8((raw >> 24) & 0xff),
            ]

            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("en") {
                if preferred == nil { preferred = bytes }
            } else if fallback == nil {
                fallback = bytes
            }
        }

        return preferred ?? fallback ?? [0, 0, 0, 0]
    }

    public static func describe(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "0.0.0.0" }
        return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
    }
}
