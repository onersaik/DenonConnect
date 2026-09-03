// NetworkInfo.swift
// Datos de la interfaz de red local. Necesarios porque el paquete de presencia
// Pro DJ Link debe incluir nuestra propia IP para que los CDJ sepan a dónde
// enviarnos el estado detallado.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum NetworkInfo {
    private struct IPv4Iface {
        let name: String
        let ip: [UInt8]
        let netmask: [UInt8]
    }

    /// IPv4 de la primera interfaz activa que no sea loopback, como 4 bytes.
    /// Prioriza interfaces "en" (Ethernet/Wi-Fi en macOS) sobre el resto.
    public static func localIPv4Bytes() -> [UInt8] {
        localIPv4Bytes(reaching: nil)
    }

    /// IPv4 local que puede alcanzar `peerIP` (misma subred). Si no hay
    /// coincidencia, la `en*` preferida — nunca se inventa otra player IP.
    public static func localIPv4Bytes(reaching peerIP: String?) -> [UInt8] {
        let ifaces = collectIPv4Ifaces(includeLoopback: false)
        if let peerIP, let peer = ipv4Bytes(from: peerIP) {
            if let match = ifaces.first(where: {
                $0.name.hasPrefix("en") && sameSubnet($0.ip, $0.netmask, peer)
            }) {
                return match.ip
            }
            if let match = ifaces.first(where: { sameSubnet($0.ip, $0.netmask, peer) }) {
                return match.ip
            }
        }
        if let en = ifaces.first(where: { $0.name.hasPrefix("en") }) {
            return en.ip
        }
        return ifaces.first?.ip ?? [0, 0, 0, 0]
    }

    /// CDJ de LAN al que cabe unicast del keepalive virtual. Excluye loopback,
    /// broadcast y este Mac (Pioneer TEST / Dual local no reciben spam).
    public static func isLANUnicastTarget(_ ip: String) -> Bool {
        guard let bytes = ipv4Bytes(from: ip) else { return false }
        if bytes[0] == 127 { return false }
        if bytes == [255, 255, 255, 255] { return false }
        if isLocalIPv4(ip) { return false }
        return true
    }

    public static func ipv4Bytes(from string: String) -> [UInt8]? {
        guard !string.isEmpty else { return nil }
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        let raw = addr.s_addr
        let bytes: [UInt8] = [
            UInt8(raw & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 24) & 0xff),
        ]
        if bytes == [0, 0, 0, 0] { return nil }
        return bytes
    }

    private static func sameSubnet(_ ip: [UInt8], _ mask: [UInt8], _ peer: [UInt8]) -> Bool {
        guard ip.count == 4, mask.count == 4, peer.count == 4 else { return false }
        for i in 0..<4 {
            if (ip[i] & mask[i]) != (peer[i] & mask[i]) { return false }
        }
        return true
    }

    private static func collectIPv4Ifaces(includeLoopback: Bool) -> [IPv4Iface] {
        var result: [IPv4Iface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return result }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor = ifaddrPtr
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            guard let addr = interface.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isLoopback && !includeLoopback { continue }

            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let raw = sin.sin_addr.s_addr
            let ip: [UInt8] = [
                UInt8(raw & 0xff),
                UInt8((raw >> 8) & 0xff),
                UInt8((raw >> 16) & 0xff),
                UInt8((raw >> 24) & 0xff),
            ]
            if ip == [0, 0, 0, 0] { continue }

            var netmask: [UInt8] = [255, 255, 255, 255]
            if let maskPtr = interface.ifa_netmask, maskPtr.pointee.sa_family == UInt8(AF_INET) {
                let msin = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let mraw = msin.sin_addr.s_addr
                netmask = [
                    UInt8(mraw & 0xff),
                    UInt8((mraw >> 8) & 0xff),
                    UInt8((mraw >> 16) & 0xff),
                    UInt8((mraw >> 24) & 0xff),
                ]
            }

            result.append(IPv4Iface(
                name: String(cString: interface.ifa_name),
                ip: ip,
                netmask: netmask
            ))
        }
        return result
    }

    public static func describe(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "0.0.0.0" }
        return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
    }

    /// Todas las IPv4 locales (interfaces activas + loopback). Sirve para
    /// reconocer el CDJ virtual y el simulador TEST en este mismo Mac.
    public static func localIPv4Addresses() -> Set<String> {
        var result: Set<String> = ["127.0.0.1"]
        for iface in collectIPv4Ifaces(includeLoopback: true) {
            result.insert(describe(iface.ip))
        }
        return result
    }

    public static func isLocalIPv4(_ ip: String) -> Bool {
        guard !ip.isEmpty, ip != "0.0.0.0" else { return false }
        return localIPv4Addresses().contains(ip)
    }

    /// MAC de la interfaz cuyo IPv4 coincide con `localIPv4Bytes()`.
    /// Los CDJ ignoran un CDJ virtual con MAC 00:00:00:00:00:00.
    public static func localMACBytes() -> [UInt8] {
        localMACBytes(forIPv4: localIPv4Bytes())
    }

    public static func localMACBytes(forIPv4 ip: [UInt8]) -> [UInt8] {
        let ipName = interfaceName(forIPv4: ip)
        var fallback: [UInt8]?

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return locallyAdministeredMAC(from: ip) }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor = ifaddrPtr
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard let addr = interface.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: interface.ifa_name)
            guard let mac = macFromLinkAddress(addr) else { continue }
            if let ipName, name == ipName { return mac }
            if name.hasPrefix("en"), fallback == nil { fallback = mac }
        }
        return fallback ?? locallyAdministeredMAC(from: ip)
    }

    public static func describeMAC(_ bytes: [UInt8]) -> String {
        guard bytes.count == 6 else { return "00:00:00:00:00:00" }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func interfaceName(forIPv4 ip: [UInt8]) -> String? {
        guard ip.count == 4, ip != [0, 0, 0, 0] else { return nil }
        return collectIPv4Ifaces(includeLoopback: false).first(where: { $0.ip == ip })?.name
    }

    private static func macFromLinkAddress(_ addr: UnsafePointer<sockaddr>) -> [UInt8]? {
        let sdl = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
        let alen = Int(sdl.sdl_alen)
        guard alen == 6 else { return nil }
        let nlen = Int(sdl.sdl_nlen)
        var mac = [UInt8](repeating: 0, count: 6)
        withUnsafeBytes(of: sdl.sdl_data) { raw in
            guard raw.count >= nlen + 6 else { return }
            for i in 0..<6 { mac[i] = raw[nlen + i] }
        }
        if mac.allSatisfy({ $0 == 0 }) { return nil }
        return mac
    }

    private static func locallyAdministeredMAC(from ip: [UInt8]) -> [UInt8] {
        [
            0x02,
            ip.count > 0 ? ip[0] : 0,
            ip.count > 1 ? ip[1] : 0,
            ip.count > 2 ? ip[2] : 0,
            ip.count > 3 ? ip[3] : 0,
            0x07,
        ]
    }
}
