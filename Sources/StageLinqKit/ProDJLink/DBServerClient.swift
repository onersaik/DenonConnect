// DBServerClient.swift
// Protocolo Pioneer DBSERVER — consulta título, artista y tonalidad desde CDJ.
//
// Flujo:
//   1. Puerto 12523 → descubrir puerto DB (siempre 1051 en la práctica).
//   2. Puerto 1051  → sesión TCP con saludo + GetMetadata + RenderMenu.
//   3. Parsear ítems de respuesta (tipo 0x4101) con cadenas UTF-16BE.
//
// ENTIK MEDIA

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Resultado

public struct DBServerMeta: Sendable {
    public var title:  String
    public var artist: String
    public var key:    String
    public var genre:  String
    public var album:  String
    public var comment: String
    /// ID de portada en rekordbox (ítem 0x0a). 0 = el CDJ no lo mandó.
    public var artworkId: UInt32

    public static let empty = DBServerMeta(
        title: "", artist: "", key: "", genre: "", album: "", comment: "", artworkId: 0
    )
}

/// Preview de waveform que algunos CDJ (NXS2 / 3000) exponen por dbserver.
/// Vacío = el reproductor no mandó picos.
public struct DBServerWaveform: Sendable {
    public var peaks: [UInt8]
    public var peaksLow: [UInt8]
    public var peaksMid: [UInt8]
    public var peaksHigh: [UInt8]

    public var hasRGB: Bool {
        let n = peaksLow.count
        return n > 1 && peaksMid.count == n && peaksHigh.count == n
    }
}

// MARK: - Cliente

public final class DBServerClient {

    // MARK: API pública

    /// Consulta metadatos de pista. Sincrónico — llamar en hilo de fondo.
    /// `queryPlayer` es solo el número en el paquete TCP (0 = ordenador / rekordbox).
    /// No anuncia presencia Pro DJ Link como ese player.
    /// - Parameters:
    ///   - ip:      Dirección IP del reproductor Pioneer.
    ///   - slot:    CDJStatus.Slot.rawValue (cd=1, sd=2, usb=3, rekordbox=4).
    ///   - trackID: ID de la pista en el slot.
    ///   - queryPlayer: Player que el CDJ ve en la petición (0 o hueco 1–6).
    public static func query(ip: String, slot: Int, trackID: UInt32,
                             queryPlayer: UInt8 = 0,
                             timeout: TimeInterval = 3.0) -> DBServerMeta? {
        guard trackID > 0, (1...4).contains(slot) else { return nil }

        // Descubrir puerto DB; si falla, usar 1051 directamente
        let dbPort: UInt16 = discoverDBPort(ip: ip, timeout: min(timeout, 1.5)) ?? 1051

        return fetchMetadata(ip: ip, port: dbPort,
                             slot: UInt8(slot), trackID: trackID,
                             queryPlayer: queryPlayer, timeout: timeout)
    }

    /// Preview de waveform (GetWaveformPreview 0x2004). Nil si el CDJ no responde.
    public static func queryWaveform(ip: String, slot: Int, trackID: UInt32,
                                    queryPlayer: UInt8 = 0,
                                    timeout: TimeInterval = 2.5) -> DBServerWaveform? {
        guard trackID > 0, (1...4).contains(slot) else { return nil }
        let dbPort: UInt16 = discoverDBPort(ip: ip, timeout: min(timeout, 1.2)) ?? 1051
        return fetchWaveform(ip: ip, port: dbPort,
                             slot: UInt8(slot), trackID: trackID,
                             queryPlayer: queryPlayer, timeout: timeout)
    }

    /// GetArtwork (0x2003). Misma plantilla que GetMetadata; el último entero es el artwork ID.
    /// Nil si no hay ID o el CDJ no mandó JPEG. No se inventa con el trackID.
    public static func queryArtwork(ip: String, slot: Int, artworkId: UInt32,
                                   queryPlayer: UInt8 = 0,
                                   timeout: TimeInterval = 2.5) -> Data? {
        guard artworkId > 0, (1...4).contains(slot) else { return nil }
        let dbPort: UInt16 = discoverDBPort(ip: ip, timeout: min(timeout, 1.2)) ?? 1051
        return fetchArtwork(ip: ip, port: dbPort,
                            slot: UInt8(slot), artworkId: artworkId,
                            queryPlayer: queryPlayer, timeout: timeout)
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
                                      queryPlayer: UInt8,
                                      timeout: TimeInterval) -> DBServerMeta? {
        guard let conn = try? TCPConnection(host: ip, port: port,
                                            timeoutSeconds: max(2, Int(timeout))) else { return nil }
        defer { conn.close() }
        conn.setReadTimeout(milliseconds: 500)

        // Saludo → esperar eco del servidor
        guard (try? conn.send(greetingBytes(player: queryPlayer))) != nil else { return nil }
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
        guard (try? conn.send(buildGetMetadata(txid: txid, slot: slot, trackID: trackID,
                                               queryPlayer: queryPlayer))) != nil
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
        guard (try? conn.send(buildRenderMenu(txid: txid, slot: slot, count: count,
                                              queryPlayer: queryPlayer))) != nil
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
        var meta = parseResponse(renderBuf)
        if meta.artworkId == 0 {
            meta.artworkId = parseArtworkId(renderBuf)
        }
        if meta.artworkId == 0 {
            meta.artworkId = parseArtworkId(metaBuf)
        }
        // Exigir al menos título o artista para considerarlo válido
        guard !meta.title.isEmpty || !meta.artist.isEmpty else { return nil }
        return meta
    }

    private static func fetchWaveform(ip: String, port: UInt16,
                                     slot: UInt8, trackID: UInt32,
                                     queryPlayer: UInt8,
                                     timeout: TimeInterval) -> DBServerWaveform? {
        guard let conn = try? TCPConnection(host: ip, port: port,
                                            timeoutSeconds: max(2, Int(timeout))) else { return nil }
        defer { conn.close() }
        conn.setReadTimeout(milliseconds: 400)

        guard (try? conn.send(greetingBytes(player: queryPlayer))) != nil else { return nil }
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

        guard (try? conn.send(buildGetWaveformPreview(txid: 1, slot: slot, trackID: trackID,
                                                      queryPlayer: queryPlayer))) != nil
        else { return nil }

        var buf = Data()
        for _ in 0..<16 {
            do {
                if let c = try conn.receive(maxBytes: 4096) { buf.append(c) }
                else { break }
            } catch { break }
        }
        return parseWaveform(buf)
    }

    private static func fetchArtwork(ip: String, port: UInt16,
                                    slot: UInt8, artworkId: UInt32,
                                    queryPlayer: UInt8,
                                    timeout: TimeInterval) -> Data? {
        guard let conn = try? TCPConnection(host: ip, port: port,
                                            timeoutSeconds: max(2, Int(timeout))) else { return nil }
        defer { conn.close() }
        conn.setReadTimeout(milliseconds: 400)

        guard (try? conn.send(greetingBytes(player: queryPlayer))) != nil else { return nil }
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

        guard (try? conn.send(buildGetArtwork(txid: 1, slot: slot, artworkId: artworkId,
                                              queryPlayer: queryPlayer))) != nil
        else { return nil }

        var buf = Data()
        for _ in 0..<20 {
            do {
                if let c = try conn.receive(maxBytes: 8192) { buf.append(c) }
                else { break }
            } catch { break }
        }
        return extractJPEG(buf)
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

    /// Saludo al puerto 1051. El entero final es el player de la petición
    /// (`0` = cliente ordenador; no es el CDJ virtual 7 de presencia UDP).
    private static func greetingBytes(player: UInt8) -> Data {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        let hex = String(format: "0123456789abcdef0000000f11%08x", player)
        return Data((xml + hex).utf8)
    }

    /// GetMetadata (tipo 0x2002) — 45 bytes.
    /// TxID en bytes [6..9], queryPlayer en [15] y [37], slot en [38], trackID en [41..44].
    private static func buildGetMetadata(txid: UInt32, slot: UInt8, trackID: UInt32,
                                         queryPlayer: UInt8) -> Data {
        var b: [UInt8] = [
            0x11,0x87,0x23,0x49,0xAE, 0x11,0x00,0x00,0x00,0x01,    // 0-9
            0x10,0x20,0x02, 0x00, 0x0f,0x01,                         // 10-15
            0x14,0x00,0x10,                                           // 16-18 (blob tag + len=16)
            // blob 16 bytes (19-34):
            0x00,0x00,0x0c,0x06,0x06,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
            // post-blob (35-44): …0f [player] [slot] 01 06 [trackID 4b]
            0x00, 0x0f,0x01, 0x03, 0x01,                             // 35-39
            0x06, 0x00,0x00,0x04,0x1c                                 // 40-44
        ]
        // TxID
        b[6] = UInt8((txid >> 24) & 0xFF); b[7] = UInt8((txid >> 16) & 0xFF)
        b[8] = UInt8((txid >>  8) & 0xFF); b[9] = UInt8( txid        & 0xFF)
        // Player de la consulta (no anuncia presencia)
        b[15] = queryPlayer
        b[37] = queryPlayer
        // Slot
        b[38] = slot
        // TrackID
        b[41] = UInt8((trackID >> 24) & 0xFF); b[42] = UInt8((trackID >> 16) & 0xFF)
        b[43] = UInt8((trackID >>  8) & 0xFF); b[44] = UInt8( trackID        & 0xFF)
        return Data(b)
    }

    /// GetWaveformPreview (tipo 0x2004). Misma plantilla que GetMetadata (0x2002).
    private static func buildGetWaveformPreview(txid: UInt32, slot: UInt8, trackID: UInt32,
                                                queryPlayer: UInt8) -> Data {
        var b = [UInt8](buildGetMetadata(txid: txid, slot: slot, trackID: trackID,
                                         queryPlayer: queryPlayer))
        if b.count > 12 { b[12] = 0x04 }
        return Data(b)
    }

    /// GetArtwork (tipo 0x2003). El campo trackID de la plantilla es el artwork ID.
    private static func buildGetArtwork(txid: UInt32, slot: UInt8, artworkId: UInt32,
                                        queryPlayer: UInt8) -> Data {
        var b = [UInt8](buildGetMetadata(txid: txid, slot: slot, trackID: artworkId,
                                         queryPlayer: queryPlayer))
        if b.count > 12 { b[12] = 0x03 }
        return Data(b)
    }

    /// RenderMenu (tipo 0x3000) — 63 bytes.
    /// TxID en bytes [6..9], slot en byte [36], count en bytes [44..47] y [54..57].
    private static func buildRenderMenu(txid: UInt32, slot: UInt8, count: UInt32,
                                        queryPlayer _: UInt8) -> Data {
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
        var title = "", artist = "", key = "", genre = "", album = "", comment = ""
        let artworkId = parseArtworkId(data)
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
                case 0x05: if genre.isEmpty  { genre  = str }
                case 0x02: if album.isEmpty  { album  = str }
                case 0x17: if comment.isEmpty { comment = str }
                case 0x0d: break   // BPM×100 — no se usa
                default: break
                }
            }

            i += 12  // avanzar al menos la cabecera
        }

        return DBServerMeta(title: title, artist: artist, key: key, genre: genre, album: album, comment: comment, artworkId: artworkId)
    }

    /// Ítem de menú 0x0a = ARTWORK. El entero que no es el tipo es el ID rekordbox.
    private static func parseArtworkId(_ data: Data) -> UInt32 {
        let b = [UInt8](data)
        var i = 0
        var found: UInt32 = 0
        let typeTags: Set<UInt32> = [0x02, 0x04, 0x05, 0x07, 0x0a, 0x0d, 0x0f, 0x17]
        while i + 12 < b.count {
            guard b[i] == 0x11, b[i+1] == 0x87, b[i+2] == 0x23,
                  b[i+3] == 0x49, b[i+4] == 0xAE else { i += 1; continue }
            guard i + 11 < b.count, b[i+9] == 0x10, b[i+10] == 0x41, b[i+11] == 0x01 else {
                i += 5
                continue
            }
            var pos = i + 12
            let end = min(pos + 256, b.count)
            var ints: [UInt32] = []
            while pos < end {
                if pos + 4 < end, b[pos] == 0x11, b[pos+1] == 0x87 { break }
                if b[pos] == 0x11, pos + 4 < end {
                    let v = UInt32(b[pos+1]) << 24 | UInt32(b[pos+2]) << 16 |
                            UInt32(b[pos+3]) << 8 | UInt32(b[pos+4])
                    ints.append(v)
                    pos += 5
                    continue
                }
                if b[pos] == 0x0f, pos + 1 < end {
                    ints.append(UInt32(b[pos+1]))
                    pos += 2
                    continue
                }
                if b[pos] == 0x10, pos + 2 < end {
                    ints.append(UInt32(b[pos+1]) << 8 | UInt32(b[pos+2]))
                    pos += 3
                    continue
                }
                if b[pos] == 0x14, pos + 2 < end {
                    let len = Int(b[pos+1]) << 8 | Int(b[pos+2])
                    pos = min(end, pos + 3 + max(0, len))
                    continue
                }
                if b[pos] == 0x26, pos + 4 < end {
                    let chars = Int(b[pos+3]) << 8 | Int(b[pos+4])
                    pos = min(end, pos + 5 + max(0, chars * 2))
                    continue
                }
                pos += 1
            }
            if ints.contains(0x0a) {
                if let id = ints.first(where: { $0 > 0 && !typeTags.contains($0) }) {
                    found = id
                    break
                }
            }
            i += 12
        }
        return found
    }

    private static func extractJPEG(_ data: Data) -> Data? {
        guard data.count > 32 else { return nil }
        let start: Data.Index
        if let jpeg = data.range(of: Data([0xFF, 0xD8, 0xFF])) {
            start = jpeg.lowerBound
        } else if let png = data.range(of: Data([0x89, 0x50, 0x4E, 0x47])) {
            start = png.lowerBound
        } else {
            return nil
        }
        var slice = data.subdata(in: start..<data.count)
        if slice.starts(with: [0xFF, 0xD8]), let end = slice.range(of: Data([0xFF, 0xD9])) {
            slice = slice.subdata(in: slice.startIndex..<end.upperBound)
        }
        return slice.count > 32 ? slice : nil
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
                guard pos + 1 < end else { return resultOrNil(knownType, anySmall, resultStr) }
                pos += 2

            case 0x10:   // entero 2 bytes
                guard pos + 2 < end else { return resultOrNil(knownType, anySmall, resultStr) }
                pos += 3

            case 0x11:   // entero 4 bytes
                guard pos + 4 < end else { return resultOrNil(knownType, anySmall, resultStr) }
                let v = Int(b[pos+1]) << 24 | Int(b[pos+2]) << 16 |
                        Int(b[pos+3]) << 8  | Int(b[pos+4])
                if v > 0 && v <= 0xFF {
                    anySmall = v
                    // Registrar si es un tipo de ítem conocido
                    if v == 0x02 || v == 0x04 || v == 0x05 || v == 0x07 ||
                       v == 0x0d || v == 0x0f || v == 0x17 {
                        knownType = v
                    }
                }
                pos += 5

            case 0x14:   // blob con longitud 2 bytes
                guard pos + 2 < end else { return resultOrNil(knownType, anySmall, resultStr) }
                let blobLen = Int(b[pos+1]) << 8 | Int(b[pos+2])
                let next = pos + 3 + max(0, blobLen)
                guard next <= end, next > pos else { return resultOrNil(knownType, anySmall, resultStr) }
                pos = next

            case 0x26:   // cadena UTF-16BE: [tag][lenHi][lenLo][countHi][countLo][chars…]
                guard pos + 4 < end else { return resultOrNil(knownType, anySmall, resultStr) }
                let charCount = Int(b[pos+3]) << 8 | Int(b[pos+4])
                let remain = end - (pos + 5)
                let byteLen = min(max(0, charCount * 2), max(0, remain))
                let dataStart = pos + 5
                if resultStr.isEmpty, byteLen > 0, dataStart + byteLen <= end, dataStart + byteLen <= b.count {
                    let slice = Array(b[dataStart..<(dataStart + byteLen)])
                    if let s = String(bytes: slice, encoding: .utf16BigEndian) {
                        let t = s.trimmingCharacters(in: .controlCharacters)
                                 .trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { resultStr = t }
                    }
                }
                pos = dataStart + byteLen

            default:
                pos += 1
            }

            if !resultStr.isEmpty && (knownType >= 0 || anySmall >= 0) { break }
        }

        return resultOrNil(knownType, anySmall, resultStr)
    }

    private static func resultOrNil(_ knownType: Int, _ anySmall: Int, _ resultStr: String) -> (Int, String)? {
        guard !resultStr.isEmpty else { return nil }
        let finalType = knownType >= 0 ? knownType : anySmall
        guard finalType > 0 else { return nil }
        return (finalType, resultStr)
    }

    private static func parseWaveform(_ data: Data) -> DBServerWaveform? {
        guard data.count >= 200 else { return nil }
        let b = [UInt8](data)
        var blobs: [ArraySlice<UInt8>] = []
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0x14 {
                let len = Int(b[i + 1]) << 8 | Int(b[i + 2])
                if len >= 200, i + 3 + len <= b.count {
                    blobs.append(b[(i + 3)..<(i + 3 + len)])
                    i += 3 + len
                    continue
                }
            }
            i += 1
        }
        let raw: [UInt8]
        if let best = blobs.max(by: { $0.count < $1.count }) {
            raw = Array(best)
        } else if data.count >= 400, data.count <= 8000 {
            raw = b
        } else {
            return nil
        }
        return interpretWaveformBytes(raw)
    }

    private static func interpretWaveformBytes(_ raw: [UInt8]) -> DBServerWaveform? {
        guard raw.count >= 200 else { return nil }
        if raw.count % 3 == 0, raw.count >= 600 {
            let n = raw.count / 3
            var low = [UInt8](repeating: 0, count: n)
            var mid = [UInt8](repeating: 0, count: n)
            var high = [UInt8](repeating: 0, count: n)
            var mx: UInt8 = 0
            for i in 0..<n {
                mid[i] = raw[i * 3]
                high[i] = raw[i * 3 + 1]
                low[i] = raw[i * 3 + 2]
                mx = max(mx, max(low[i], max(mid[i], high[i])))
            }
            if mx < 32 {
                for i in 0..<n {
                    low[i] = UInt8(min(255, Int(low[i]) * 8))
                    mid[i] = UInt8(min(255, Int(mid[i]) * 8))
                    high[i] = UInt8(min(255, Int(high[i]) * 8))
                }
            }
            let peaks = (0..<n).map { max(low[$0], mid[$0], high[$0]) }
            return DBServerWaveform(peaks: peaks, peaksLow: low, peaksMid: mid, peaksHigh: high)
        }
        let peaks = raw.map { byte -> UInt8 in
            let h = byte & 0x1f
            return UInt8(min(255, Int(h) * 8))
        }
        guard peaks.contains(where: { $0 > 8 }) else { return nil }
        return DBServerWaveform(peaks: peaks, peaksLow: [], peaksMid: [], peaksHigh: [])
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
