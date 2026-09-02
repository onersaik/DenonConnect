// DJLinkProtocol.swift
// Protocolo Pioneer/AlphaTheta Pro DJ Link (CDJ-3000, CDJ-2000NXS2, XDJ, DJM…).
//
// OJO: esto NO es StageLinq. Los CDJ hablan un protocolo completamente
// distinto al de los Denon/Engine OS. Los offsets de bytes de este archivo
// están verificados contra dos fuentes independientes que coinciden entre sí:
//   · Deep Symmetry "dysentery" (documentación de ingeniería inversa)
//     https://djl-analysis.deepsymmetry.org
//   · flesniak/python-prodj-link (implementación real en Python)
// Las tres fuentes coinciden en BPM (0x92), contador de beat (0xa0),
// beat dentro del compás (0xa6) y bits de estado (0x89).

import Foundation

public enum DJLink {
    /// Todos los paquetes Pro DJ Link empiezan por esta cabecera fija.
    public static let magic: [UInt8] = [0x51, 0x73, 0x70, 0x74, 0x31, 0x57, 0x6d, 0x4a, 0x4f, 0x4c] // "Qspt1WmJOL"

    public static let keepAlivePort: UInt16 = 50000   // presencia / descubrimiento
    public static let beatPort: UInt16 = 50001        // beats (no usado todavía)
    public static let statusPort: UInt16 = 50002      // estado detallado por reproductor

    /// Número de dispositivo virtual con el que nos anunciamos. Se recomienda 7
    /// para no chocar con reproductores reales (que usan 1–6).
    public static let virtualPlayerNumber: UInt8 = 7
    public static let virtualModelName = "SC6000 Connect"

    /// Tipos de paquete (byte 0x0a).
    public enum PacketType {
        public static let keepAlive: UInt8 = 0x06   // presencia periódica
        public static let hello: UInt8 = 0x0a       // anuncio inicial / estado CDJ (según puerto)
        public static let cdjStatus: UInt8 = 0x0a   // en puerto 50002
        public static let mixerStatus: UInt8 = 0x29
    }

    /// Offsets comunes de cabecera.
    public enum Header {
        public static let type = 0x0a
        public static let keepAliveModel = 0x0c      // 20 bytes, string C null-padded
        public static let statusModel = 0x0b         // 20 bytes, string C null-padded
        public static let modelLength = 20
    }
}

// MARK: - Paquete de presencia (puerto 50000)

/// Anuncio de presencia de un dispositivo Pro DJ Link en la red.
public struct DJLinkKeepAlive {
    public var playerNumber: Int
    public var model: String
    public var ip: String

    /// Offsets verificados (struct KeepAlivePacket, variante type_status):
    /// 0x0a tipo · 0x0c-0x1f modelo · 0x24 nº reproductor · 0x2c-0x2f IP.
    public static func parse(_ data: Data) -> DJLinkKeepAlive? {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x30 else { return nil }
        guard Array(bytes[0..<10]) == DJLink.magic else { return nil }
        guard bytes[DJLink.Header.type] == DJLink.PacketType.keepAlive else { return nil }

        let model = DJLinkCodec.readPaddedString(bytes, at: DJLink.Header.keepAliveModel, length: DJLink.Header.modelLength)
        let player = Int(bytes[0x24])
        let ip = "\(bytes[0x2c]).\(bytes[0x2d]).\(bytes[0x2e]).\(bytes[0x2f])"
        return DJLinkKeepAlive(playerNumber: player, model: model, ip: ip)
    }

    /// Construye nuestro propio paquete de presencia (54 bytes / 0x36).
    /// Es lo que hace que los CDJ empiecen a enviarnos estado detallado al
    /// puerto 50002: si no nos anunciamos, no nos mandan nada.
    public static func buildVirtualCDJ(playerNumber: UInt8, model: String, ip: [UInt8], mac: [UInt8]) -> Data {
        var b = [UInt8](repeating: 0, count: 0x36)
        for (i, v) in DJLink.magic.enumerated() { b[i] = v }
        b[0x0a] = DJLink.PacketType.keepAlive
        b[0x0b] = 0x00
        DJLinkCodec.writePaddedString(model, into: &b, at: DJLink.Header.keepAliveModel, length: DJLink.Header.modelLength)
        b[0x20] = 0x01          // constante
        b[0x21] = 0x02          // device_type: 2 = CDJ
        b[0x22] = 0x00
        b[0x23] = 0x36          // subtipo emparejado con type_status
        b[0x24] = playerNumber
        b[0x25] = 0x01
        for i in 0..<6 { b[0x26 + i] = i < mac.count ? mac[i] : 0 }
        for i in 0..<4 { b[0x2c + i] = i < ip.count ? ip[i] : 0 }
        b[0x30] = 0x01          // nº de dispositivos conocidos
        b[0x34] = 0x01          // flags
        b[0x35] = 0x64
        return Data(b)
    }
}

// MARK: - Paquete de estado de CDJ (puerto 50002)

public struct CDJStatus {
    public var playerNumber: Int
    public var model: String
    public var firmware: String

    public var isPlaying: Bool
    public var isMaster: Bool
    public var isSynced: Bool
    public var isOnAir: Bool

    public var playMode: PlayMode
    public var trackLoaded: Bool
    public var trackID: UInt32
    public var trackNumber: UInt32
    public var slot: Slot

    public var trackBPM: Double      // BPM del track sin pitch
    public var pitchPercent: Double  // ±% del pitch efectivo
    public var effectiveBPM: Double  // BPM realmente sonando

    public var beatCount: Int        // beat absoluto dentro del track
    public var beatInBar: Int        // 1…4

    public enum PlayMode: Int {
        case noTrack = 0x00
        case loading = 0x02
        case playing = 0x03
        case looping = 0x04
        case paused = 0x05
        case cued = 0x06
        case cuePlay = 0x07
        case cueScratch = 0x08
        case seeking = 0x09
        case cannotPlay = 0x0e
        case endOfTrack = 0x11
        case emergency = 0x12
        case unknown = 0xff

        public var label: String {
            switch self {
            case .noTrack: return "Sin pista"
            case .loading: return "Cargando"
            case .playing: return "Play"
            case .looping: return "Loop"
            case .paused: return "Pausa"
            case .cued: return "Cue"
            case .cuePlay: return "Cue play"
            case .cueScratch: return "Cue scratch"
            case .seeking: return "Buscando"
            case .cannotPlay: return "No reproducible"
            case .endOfTrack: return "Fin de pista"
            case .emergency: return "Emergencia"
            case .unknown: return "—"
            }
        }
    }

    public enum Slot: Int {
        case empty = 0, cd = 1, sd = 2, usb = 3, rekordbox = 4
        case streamingDirect = 6, beatportLink = 9
        case other = 255

        public var label: String {
            switch self {
            case .empty: return "—"
            case .cd: return "CD"
            case .sd: return "SD"
            case .usb: return "USB"
            case .rekordbox: return "rekordbox"
            case .streamingDirect: return "Cloud"
            case .beatportLink: return "Beatport"
            case .other: return "?"
            }
        }
    }

    /// Offsets verificados (struct StatusPacket, variante "cdj"):
    /// 0x21 nº reproductor · 0x29 slot · 0x2a tipo de pista · 0x2c-0x2f ID de
    /// pista · 0x7b modo de reproducción · 0x7c-0x7f firmware · 0x89 flags
    /// (play/master/sync/on-air) · 0x92-0x93 BPM · 0x98-0x9b pitch efectivo ·
    /// 0xa0-0xa3 contador de beat · 0xa6 beat dentro del compás.
    public static func parse(_ data: Data) -> CDJStatus? {
        let b = [UInt8](data)
        guard b.count >= 0xa7 else { return nil }
        guard Array(b[0..<10]) == DJLink.magic else { return nil }
        guard b[DJLink.Header.type] == DJLink.PacketType.cdjStatus else { return nil }

        let model = DJLinkCodec.readPaddedString(b, at: DJLink.Header.statusModel, length: DJLink.Header.modelLength)
        let player = Int(b[0x21])
        let slotRaw = Int(b[0x29])
        let analyzeType = Int(b[0x2a])
        let trackID = DJLinkCodec.readUInt32(b, at: 0x2c)
        let trackNumber = DJLinkCodec.readUInt32(b, at: 0x30)
        let playModeRaw = Int(b[0x7b])
        let firmware = DJLinkCodec.readPaddedString(b, at: 0x7c, length: 4)

        let flags = b[0x89]
        let isPlaying = (flags & 0x40) != 0
        let isMaster = (flags & 0x20) != 0
        let isSynced = (flags & 0x10) != 0
        let isOnAir = (flags & 0x08) != 0

        let bpmRaw = DJLinkCodec.readUInt16(b, at: 0x92)
        // 0xffff significa "sin pista analizada".
        let trackBPM = bpmRaw == 0xffff ? 0 : Double(bpmRaw) / 100.0

        let pitchRaw = DJLinkCodec.readUInt32(b, at: 0x98)
        // 0x100000 = 0% (velocidad normal); 0x000000 = −100%; 0x200000 = +100%.
        let pitchRatio = Double(pitchRaw) / Double(0x100000)
        let pitchPercent = (pitchRatio - 1.0) * 100.0

        let beatCountRaw = DJLinkCodec.readUInt32(b, at: 0xa0)
        let beatCount = beatCountRaw == 0xffffffff ? 0 : Int(beatCountRaw)
        let beatInBar = Int(b[0xa6])

        let mode = PlayMode(rawValue: playModeRaw) ?? .unknown
        let slot = Slot(rawValue: slotRaw) ?? .other
        let trackLoaded = analyzeType != 0 && slotRaw != 0

        return CDJStatus(
            playerNumber: player,
            model: model,
            firmware: firmware,
            isPlaying: isPlaying,
            isMaster: isMaster,
            isSynced: isSynced,
            isOnAir: isOnAir,
            playMode: mode,
            trackLoaded: trackLoaded,
            trackID: trackID,
            trackNumber: trackNumber,
            slot: slot,
            trackBPM: trackBPM,
            pitchPercent: pitchPercent,
            effectiveBPM: trackBPM * pitchRatio,
            beatCount: beatCount,
            beatInBar: beatInBar
        )
    }
}

// MARK: - Paquetes del puerto de beats (50001)

/// Paquete de beat: llega justo en cada golpe, así que es la señal de
/// sincronía más precisa que emite un CDJ (mucho mejor que el estado, que
/// llega cada 200 ms).
public struct DJLinkBeat {
    public var playerNumber: Int
    public var beatInBar: Int      // 1…4
    public var bpm: Double
    public var pitchPercent: Double

    /// Offsets: 0x21 nº reproductor · 0x54-0x57 pitch · 0x5a-0x5b BPM · 0x5c beat.
    public static func parse(_ b: [UInt8]) -> DJLinkBeat? {
        guard b.count >= 0x60 else { return nil }
        let pitchRatio = Double(DJLinkCodec.readUInt32(b, at: 0x54)) / Double(0x100000)
        let bpmRaw = DJLinkCodec.readUInt16(b, at: 0x5a)
        return DJLinkBeat(
            playerNumber: Int(b[0x21]),
            beatInBar: Int(b[0x5c]),
            bpm: bpmRaw == 0xffff ? 0 : Double(bpmRaw) / 100.0,
            pitchPercent: (pitchRatio - 1.0) * 100.0
        )
    }
}

/// Posición absoluta: solo la emiten los CDJ-3000. Es la única fuente de
/// tiempo transcurrido y duración real de la pista en Pro DJ Link.
public struct DJLinkAbsolutePosition {
    public var playerNumber: Int
    public var trackLength: Double  // segundos
    public var playhead: Double     // segundos
    public var bpm: Double

    /// Offsets: 0x21 nº reproductor · 0x24-0x27 duración (s) ·
    /// 0x28-0x2b posición (ms) · 0x38-0x3b BPM ×10.
    public static func parse(_ b: [UInt8]) -> DJLinkAbsolutePosition? {
        guard b.count >= 0x3c else { return nil }
        let lengthSeconds = Double(DJLinkCodec.readUInt32(b, at: 0x24))
        let playheadMs = Double(DJLinkCodec.readUInt32(b, at: 0x28))
        let bpmRaw = Double(DJLinkCodec.readUInt32(b, at: 0x38))
        return DJLinkAbsolutePosition(
            playerNumber: Int(b[0x21]),
            trackLength: lengthSeconds,
            playhead: playheadMs / 1000.0,
            bpm: bpmRaw / 10.0
        )
    }
}

public enum DJLinkBeatPacket {
    public static let typeBeat: UInt8 = 0x28
    public static let typeAbsolutePosition: UInt8 = 0x0b

    public enum Parsed {
        case beat(DJLinkBeat)
        case position(DJLinkAbsolutePosition)
    }

    public static func parse(_ data: Data) -> Parsed? {
        let b = [UInt8](data)
        guard b.count >= 0x24 else { return nil }
        guard Array(b[0..<10]) == DJLink.magic else { return nil }

        switch b[DJLink.Header.type] {
        case typeBeat:
            if let beat = DJLinkBeat.parse(b) { return .beat(beat) }
            return nil
        case typeAbsolutePosition:
            if let pos = DJLinkAbsolutePosition.parse(b) { return .position(pos) }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Utilidades de bytes

public enum DJLinkCodec {
    public static func readUInt16(_ b: [UInt8], at i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return (UInt16(b[i]) << 8) | UInt16(b[i + 1])
    }

    public static func readUInt32(_ b: [UInt8], at i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    /// Lee una cadena ASCII rellenada con ceros.
    public static func readPaddedString(_ b: [UInt8], at i: Int, length: Int) -> String {
        guard i >= 0, i + length <= b.count else { return "" }
        var chars: [UInt8] = []
        for k in i..<(i + length) {
            let c = b[k]
            if c == 0 { break }
            chars.append(c)
        }
        return String(decoding: chars, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    public static func writePaddedString(_ s: String, into b: inout [UInt8], at i: Int, length: Int) {
        let utf8 = Array(s.utf8)
        for k in 0..<length {
            let index = i + k
            guard index < b.count else { return }
            b[index] = k < utf8.count ? utf8[k] : 0
        }
    }
}
