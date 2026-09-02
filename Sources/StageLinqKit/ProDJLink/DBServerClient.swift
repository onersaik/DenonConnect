// DBServerClient.swift
// Protocolo Pioneer DBSERVER — consulta título, artista y tonalidad desde CDJ.
//
// Flujo:
//   1. Puerto 12523 → descubrir puerto DB (siempre 1051 en la práctica).
//   2. Puerto 1051  → sesión TCP con saludo + GetMetadata + RenderMenu.
//   3. Parsear ítems de respuesta (tipo 0x4101) con cadenas UTF-16BE.
//
// entikrecords.com

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Resultado

public struct DBServerMeta: Sendable {
    public var title:  String
    public var artist: String
    public var key:    String

    public static let empty = DBServerMeta(title: "", artist: "", key: "")
}

// MARK: - Cliente

public final class DBServerClient {

    // MARK: API pública

    /// Consulta metadatos de pista. Sincrónico — llamar en hilo de fondo.
    /// - Parameters:
    ///   - ip:      Dirección IP del reproductor Pioneer.
    ///   - slot:    CDJStatus.Slot.rawValue (cd=1, sd=2, usb=3, rekordbox=4).
    ///   - trackID: ID de la pista en el slot.
    public static func query(ip: String, slot: Int, trackID: UInt32,
                             timeout: TimeInterval = 3.0) -> DBServerMeta? {
        guard trackID > 0, (1...4).contains(slot) else { return nil }

        // Descubrir puerto DB; si falla, usar 1051 directamente
        let dbPort: UInt16 = discoverDBPort(ip: ip, timeout: min(timeout, 1.5)) ?? 1051

        return fetchMetadata(ip: ip, port: dbPort,
                             slot: UInt8(slot), trackID: trackID, timeout: timeout)
    }

    // MARK: - Descubrimiento de puerto

    private static func discoverDBPort(ip: String, timeout: TimeInterval) -> UInt16? {
        guard let conn = try? TCPConnection(host: ip, port: 12523,
                                            timeoutSeconds: max(1, Int(timeout))) else { return nil }
        defer { conn.close() }
        conn.setReadTimeout(milliseconds: Int(timeout * 1000))

        guard (try? conn.send(probeBytes())) != nil else { return nil }

        do {
            guard let resp = try conn.receive(maxBytes: 8),
                  resp.count >= 2 else { return nil }
            let p = UInt16(resp[0]) << 8 | UInt16(resp[1])
            return p > 0 ? p : nil
        } catch { return nil }
    }

    // MARK: - Obtención de metadatos

    private static func fetchMetadata(ip: String, port: UInt16,
                                      slot: UInt8, trackID: UInt32,
                                      timeout: TimeInterval) -> DBServerMeta? {
        guard let conn = try? TCPConnection(host: ip, port: port,
                                            timeoutSeconds: max(2, Int(timeout))) else { return nil }
        defer { conn.close() }
        conn.setReadTimeout(milliseconds: 500)

        // Saludo → esperar eco del servidor
        guard (try? conn.send(greetingBytes())) != nil else { return nil }
        var ackOk = false
        for _ in 0..<6 {
            do {
                if let chunk = try conn.receive(maxBytes: 64), !chunk.isEmpty {
                    ackOk = chunk[0] == 0x11
                    break
                }
            } catch { break }
        }
        guard ackOk else { return nil }

        var txid: UInt32 = 1

        // GetMetadata — establece contexto de la pista
        guard (try? conn.send(buildGetMetadata(txid: txid, slot: slot, trackID: trackID))) != nil
        else { return nil }
        txid += 1

        // Recoger respuesta de GetMetadata
        var metaBuf = Data()
        for _ in 0..<8 {
            do {
                if let c = try conn.receive(maxBytes: 4096) { metaBuf.append(c)
                } else { break }
            } catch { break }
        }

        // RenderMenu — solicitar lista de ítems de metadatos
        let count = UInt32(max(extractItemCount(metaBuf), 12))
        guard (try? conn.send(buildRenderMenu(txid: txid, slot: slot, count: count))) != nil
        else { return nil }

        // Acumular respuesta completa
        var renderBuf = Data()
        for _ in 0..<20 {
            do {
                if let c = try conn.receive(maxBytes: 4096) { renderBuf.append(c)
                } else { break }
            } catch { break }
        }

        guard !renderBuf.isEmpty else { return nil }
        let meta = parseResponse(renderBuf)
        // Exigir al menos título o artista para considerarlo válido
        guard !meta.title.isEmpty || !meta.artist.isEmpty else { return nil }
        return meta
    }

    // MARK: - Constructores de paquetes

    /// Sonda al puerto 12523 para descubrir el puerto DB.
    private static func probeBytes() -> Data {
        let b: [UInt8] = [
            0x3f,0x78,0x6d,0x6c,0x20,0x76,0x65,0x72,0x73,0x69,0x6f,0x6e,0x3d,0x22,0x31,0x2e,
            0x30,0x22,0x20,0x65,0x6e,0x63,0x6f,0x64,0x69,0x6e,0x67,0x3d,0x22,0x55,0x54,0x46,
            0x2d,0x38,0x22,0x3f,0x3e,0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39,0x61,
            0x62,0x63,0x64,0x65,0x66,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x66,0x52,0x65,0x6d,
            0x6f,0x74,0x65,0x44,0x42,0x53,0x65,0x72,0x76,0x00,0x31,0x30,0x65,0x72,0x00
        ]
        return Data(b)
    }

    /// Saludo al puerto 1051 para iniciar sesión de metadatos.
    private static func greetingBytes() -> Data {
        let b: [UInt8] = [
            0x3f,0x78,0x6d,0x6c,0x20,0x76,0x65,0x72,0x73,0x69,0x6f,0x6e,0x3d,0x22,0x31,0x2e,
            0x30,0x22,0x20,0x65,0x6e,0x63,0x6f,0x64,0x69,0x6e,0x67,0x3d,0x22,0x55,0x54,0x46,
            0x2d,0x38,0x22,0x3f,0x3e,0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39,0x61,
            0x62,0x63,0x64,0x65,0x66,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x66,0x31,0x31,0x30,
            0x30,0x30,0x30,0x30,0x30,0x31
        ]
        return Data(b)
    }

    /// GetMetadata (tipo 0x2002) — 45 bytes.
    /// TxID en bytes [6..9], slot en byte [38], trackID en bytes [41..44].
    private static func buildGetMetadata(txid: UInt32, slot: UInt8, trackID: UInt32) -> Data {
        var b: [UInt8] = [
            0x11,0x87,0x23,0x49,0xAE, 0x11,0x00,0x00,0x00,0x01,    // 0-9
            0x10,0x20,0x02, 0x00, 0x0f,0x01,                         // 10-15
            0x14,0x00,0x10,                                           // 16-18 (blob tag + len=16)
            // blob 16 bytes (19-34):
            0x00,0x00,0x0c,0x06,0x06,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
            // post-blob (35-44): …0f 01 [slot] 01 06 [trackID 4b]
            0x00, 0x0f,0x01, 0x03, 0x01,                             // 35-39
            0x06, 0x00,0x00,0x04,0x1c                                 // 40-44
        ]
        // TxID
        b[6] = UInt8((txid >> 24) & 0xFF); b[7] = UInt8((txid >> 16) & 0xFF)
        b[8] = UInt8((txid >>  8) & 0xFF); b[9] = UInt8( txid        & 0xFF)
        // Slot
        b[38] = slot
        // TrackID
        b[41] = UInt8((trackID >> 24) & 0xFF); b[42] = UInt8((trackID >> 16) & 0xFF)
        b[43] = UInt8((trackID >>  8) & 0xFF); b[44] = UInt8( trackID        & 0xFF)
        return Data(b)
    }

    /// RenderMenu (tipo 0x3000) — 63 bytes.
    /// TxID en bytes [6..9], slot en byte [36], count en bytes [44..47] y [54..57].
    private static func buildRenderMenu(txid: UInt32, slot: UInt8, count: UInt32) -> Data {
        var b: [UInt8] = [
            0x11,0x87,0x23,0x49,0xAE, 0x11,0x00,0x00,0x00,0x02,    // 0-9
            0x10,0x30,0x00, 0x06, 0x0f,0x06,                         // 10-15
            0x14,0x00,0x10,                                           // 16-18 (blob tag + len=16)
            // blob 16 bytes (19-34):
            0x00,0x00,0x0c,0x06,0x06,0x06,0x06,0x06,
            0x06,0x00,0x00,0x00,0x00,0x00,0x00,0x0f,
            // post-blob (35-62):
            0x01, 0x03, 0x01,                                         // 35-37 (slot en [36])
            0x11,0x00,0x00,0x00,0x00,                                 // 38-42 (offset=0)
            0x11,0x00,0x00,0x00,0x0b,                                 // 43-47 (count, bytes 44-47)
            0x11,0x00,0x00,0x00,0x00,                                 // 48-52 (offset2=0)
            0x11,0x00,0x00,0x00,0x0b,                                 // 53-57 (total, bytes 54-57)
            0x11,0x00,0x00,0x00,0x00                                  // 58-62
        ]
        // TxID
        b[6] = UInt8((txid >> 24) & 0xFF); b[7] = UInt8((txid >> 16) & 0xFF)
        b[8] = UInt8((txid >>  8) & 0xFF); b[9] = UInt8( txid        & 0xFF)
        // Slot
        b[36] = slot
        // Count (límite y total)
        b[44] = UInt8((count >> 24) & 0xFF); b[45] = UInt8((count >> 16) & 0xFF)
        b[46] = UInt8((count >>  8) & 0xFF); b[47] = UInt8( count        & 0xFF)
        b[54] = UInt8((count >> 24) & 0xFF); b[55] = UInt8((count >> 16) & 0xFF)
        b[56] = UInt8((count >>  8) & 0xFF); b[57] = UInt8( count        & 0xFF)
        return Data(b)
    }

    // MARK: - Parseo de respuesta

    private static func parseResponse(_ data: Data) -> DBServerMeta {
        var title = "", artist = "", key = ""
        let b = [UInt8](data)
        var i = 0

        while i + 12 < b.count {
            // Buscar cabecera de MenuItem: magic Pioneer (11 87 23 49 AE)
            guard b[i] == 0x11, b[i+1] == 0x87, b[i+2] == 0x23,
                  b[i+3] == 0x49, b[i+4] == 0xAE else { i += 1; continue }

            // Verificar tipo 0x4101 en bytes [i+9..i+11]: 10 41 01
            guard i + 11 < b.count,
                  b[i+9] == 0x10, b[i+10] == 0x41, b[i+11] == 0x01 else {
                i += 5; continue
            }

            // Parsear argumentos del ítem
            if let (itemType, str) = extractItemFields(b, msgStart: i + 12) {
                switch itemType {
                case 0x04: if title.isEmpty  { title  = str }
                case 0x07: if artist.isEmpty { artist = str }
                case 0x0f: if key.isEmpty    { key    = str }
                case 0x02: break   // álbum — no se usa
                case 0x0d: break   // BPM×100 — no se usa
                default: break
                }
            }

            i += 12  // avanzar al menos la cabecera
        }

        return DBServerMeta(title: title, artist: artist, key: key)
    }

    /// Extrae tipo de ítem (entero 0x11 pequeño) y cadena UTF-16BE (tag 0x26)
    /// de los argumentos de un mensaje MenuItem.
    private static func extractItemFields(_ b: [UInt8], msgStart: Int) -> (Int, String)? {
        let end = min(msgStart + 512, b.count)
        var pos = msgStart
        var knownType = -1    // tipo de metadato conocido (title/artist/key)
        var anySmall  = -1    // último entero pequeño visto (candidato)
        var resultStr = ""

        while pos < end {
            // Parar si encontramos la cabecera del siguiente mensaje
            if pos + 4 < end, b[pos] == 0x11, b[pos+1] == 0x87,
               b[pos+2] == 0x23, b[pos+3] == 0x49 { break }

            let tag = b[pos]
            switch tag {
            case 0x0f:   // entero 1 byte
                pos += 2

            case 0x10:   // entero 2 bytes
                pos += 3

            case 0x11:   // entero 4 bytes
                if pos + 4 < end {
                    let v = Int(b[pos+1]) << 24 | Int(b[pos+2]) << 16 |
                            Int(b[pos+3]) << 8  | Int(b[pos+4])
                    if v > 0 && v <= 0xFF {
                        anySmall = v
                        // Registrar si es un tipo de ítem conocido
                        if v == 0x02 || v == 0x04 || v == 0x07 ||
                           v == 0x0d || v == 0x0f {
                            knownType = v
                        }
                    }
                }
                pos += 5

            case 0x14:   // blob con longitud 2 bytes
                if pos + 2 < end {
                    let blobLen = Int(b[pos+1]) << 8 | Int(b[pos+2])
                    pos += 3 + max(0, blobLen)
                } else { pos += 1 }

            case 0x26:   // cadena UTF-16BE: [tag][lenHi][lenLo][countHi][countLo][chars…]
                if pos + 4 < end {
                    let charCount = Int(b[pos+3]) << 8 | Int(b[pos+4])
                    let byteLen   = charCount * 2
                    let dataStart = pos + 5
                    if resultStr.isEmpty && dataStart + byteLen <= end {
                        let slice = Array(b[dataStart..<(dataStart + byteLen)])
                        if let s = String(bytes: slice, encoding: .utf16BigEndian) {
                            let t = s.trimmingCharacters(in: .controlCharacters)
                                     .trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty { resultStr = t }
                        }
                    }
                    pos += 5 + max(0, byteLen)
                } else { pos += 1 }

            default:
                pos += 1
            }

            if !resultStr.isEmpty && (knownType >= 0 || anySmall >= 0) { break }
        }

        guard !resultStr.isEmpty else { return nil }
        let finalType = knownType >= 0 ? knownType : anySmall
        guard finalType > 0 else { return nil }
        return (finalType, resultStr)
    }

    private static func extractItemCount(_ data: Data) -> Int {
        let b = [UInt8](data)
        var i = 0
        while i + 4 < b.count {
            if b[i] == 0x11 {
                let v = Int(b[i+1]) << 24 | Int(b[i+2]) << 16 |
                        Int(b[i+3]) << 8  | Int(b[i+4])
                if v > 0 && v <= 100 { return v }
            }
            i += 1
        }
        return 12
    }
}
