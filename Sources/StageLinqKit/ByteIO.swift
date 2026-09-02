// ByteIO.swift
// Lectura/escritura binaria Big Endian para el protocolo StageLinq.
// Todo el protocolo StageLinq usa Big Endian y, para strings, UTF-16 Big Endian
// con un prefijo de longitud en bytes (uint32).

import Foundation

public enum ByteReaderError: Error {
    case outOfBounds
    case invalidData(String)
}

/// Lector secuencial de un buffer de bytes, Big Endian.
public final class ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ data: Data) { self.bytes = Array(data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public func readUInt8() throws -> UInt8 {
        guard offset + 1 <= bytes.count else { throw ByteReaderError.outOfBounds }
        defer { offset += 1 }
        return bytes[offset]
    }

    public func readUInt16() throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw ByteReaderError.outOfBounds }
        let v = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        offset += 2
        return v
    }

    public func readUInt32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw ByteReaderError.outOfBounds }
        let v = (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        offset += 4
        return v
    }

    public func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public func readUInt64() throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw ByteReaderError.outOfBounds }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(bytes[offset + i]) }
        offset += 8
        return v
    }

    public func readFloat64() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    public func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= bytes.count else { throw ByteReaderError.outOfBounds }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    public func skip(_ n: Int) throws {
        guard n >= 0, offset + n <= bytes.count else { throw ByteReaderError.outOfBounds }
        offset += n
    }

    public func readFixedString(_ n: Int) throws -> String {
        String(decoding: try readBytes(n), as: UTF8.self)
    }

    /// Lee un "network string" StageLinq: uint32 (longitud en bytes) + UTF-16 Big Endian.
    public func readNetworkString() throws -> String {
        let byteLen = Int(try readUInt32())
        guard byteLen >= 0 else { throw ByteReaderError.invalidData("longitud negativa") }
        guard byteLen % 2 == 0 else { throw ByteReaderError.invalidData("longitud impar") }
        guard byteLen <= remaining else { throw ByteReaderError.outOfBounds }
        var units: [UInt16] = []
        units.reserveCapacity(byteLen / 2)
        for _ in 0..<(byteLen / 2) {
            units.append(try readUInt16())
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// Escritor secuencial de un buffer de bytes, Big Endian.
public final class ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public func writeUInt8(_ v: UInt8) { data.append(v) }

    public func writeUInt16(_ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    public func writeUInt32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    public func writeInt32(_ v: Int32) { writeUInt32(UInt32(bitPattern: v)) }

    public func writeBytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    public func writeData(_ d: Data) { data.append(d) }

    public func writeFixedString(_ s: String) {
        data.append(contentsOf: Array(s.utf8))
    }

    /// Escribe un "network string" StageLinq: uint32 (longitud en bytes) + UTF-16 Big Endian.
    public func writeNetworkString(_ s: String) {
        let units = Array(s.utf16)
        writeUInt32(UInt32(units.count * 2))
        for u in units { writeUInt16(u) }
    }
}
