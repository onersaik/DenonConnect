// Models.swift
// Modelos de datos observables para SwiftUI: estado de cada deck lógico y
// de cada dispositivo StageLinq descubierto.

import Foundation
import Combine

public enum PlayState: Int {
    case stopped = 0
    case playing = 1
    case paused = 2
}

/// Estado en tiempo real de un deck lógico (Deck1-A .. Deck2-B en un SC6000).
public final class DeckState: ObservableObject, Identifiable {
    public let id: Int // 1...4

    @Published public var trackTitle: String = ""
    @Published public var trackArtist: String = ""
    @Published public var trackKey: String = ""
    @Published public var genre: String = ""
    @Published public var bpm: Double = 0
    @Published public var speed: Double = 1.0
    @Published public var playState: PlayState = .stopped
    @Published public var songLoaded: Bool = false
    @Published public var loopEnabled: Bool = false
    @Published public var cuePosition: Double = -1       // segundos; -1 = sin cue
    @Published public var loopInPosition: Double = -1    // segundos; -1 = sin loop
    @Published public var loopOutPosition: Double = -1
    @Published public var loopSizeBeats: Double = 0
    @Published public var keyLock: Bool = false
    @Published public var trackLength: Double = 0 // segundos
    @Published public var volume: Double = 0
    @Published public var isMaster: Bool = false
    @Published public var scratchTouch: Bool = false
    @Published public var lastUpdate: Date = .distantPast
    /// Marca de paquete (StateMap + BeatInfo). No @Published para no saturar SwiftUI.
    public var lastPacketAt: Date = .distantPast
    /// Pulso limitado (~4 Hz) para el LED RX.
    @Published public var activityTick: UInt8 = 0
    var lastActivityPublish: Date = .distantPast

    public func pulseActivityIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastActivityPublish) >= 0.22 else { return }
        lastActivityPublish = now
        activityTick &+= 1
    }

    // Beat en vivo (servicio BeatInfo)
    /// Crudo a frecuencia de paquete; LTC / playhead leen esto sin SwiftUI.
    public var liveBeat: Double = 0
    /// Marca del último BeatInfo. Interpolación 30 fps entre paquetes.
    public var beatReceivedAt: Date = .distantPast
    @Published public var currentBeat: Double = 0
    @Published public var totalBeats: Double = 0
    @Published public var beatBpm: Double = 0
    @Published public var beatPulse: Bool = false // parpadeo visual en cada beat
    var lastBeatUIPublish: Date = .distantPast

    /// Ruta Engine Library (`TrackNetworkPath`) para FileTransfer/waveform.
    public var trackNetworkPath: String = ""
    /// Peaks overview (FileTransfer / procedural). Vacío = waveform procedural en UI.
    @Published public var peaks: [UInt8] = []
    @Published public var peaksLow: [UInt8] = []
    @Published public var peaksMid: [UInt8] = []
    @Published public var peaksHigh: [UInt8] = []

    public init(id: Int) { self.id = id }

    /// Fracción de progreso 0...1 derivada del beat, cuando hay datos de BeatInfo.
    public var beatProgress: Double? {
        guard totalBeats > 0 else { return nil }
        let beat = liveBeat > 0 ? liveBeat : currentBeat
        return min(max(beat / totalBeats, 0), 1)
    }

    /// Segundos de playhead si hay BeatInfo + duración (o totalBeats/BPM).
    public var resolvedElapsed: Double? {
        if let p = beatProgress, trackLength > 0 {
            return min(max(p * trackLength, 0), trackLength)
        }
        if totalBeats > 0, beatBpm > 0 || bpm > 0 {
            let b = liveBeat > 0 ? liveBeat : currentBeat
            let useBpm = beatBpm > 0 ? beatBpm : bpm
            return max(0, b * 60.0 / useBpm)
        }
        return nil
    }

    /// Playhead interpolado entre paquetes BeatInfo, a la velocidad real del
    /// deck (pitch/vari-speed vía `speed`). Fuente única para la UI
    /// (ContentView, elapsed en pantalla) y para el snapshot que alimenta el
    /// generador LTC (OutputController.makeDenonSnapshot) -- antes el LTC
    /// leía `resolvedElapsed`, que solo cambia cuando llega un paquete
    /// BeatInfo nuevo, mientras la UI ya mostraba esta versión suavizada:
    /// eran dos señales de posición distintas y el LTC no seguía la pista.
    public func interpolatedElapsed(playing: Bool, length: Double?) -> Double? {
        if playing, beatReceivedAt > .distantPast {
            let beat = liveBeat > 0 ? liveBeat : currentBeat
            let useBpm = beatBpm > 0 ? beatBpm : bpm
            if beat > 0, useBpm > 0 {
                let dt = min(Date().timeIntervalSince(beatReceivedAt), 2.0)
                let rate = speed > 0.05 ? speed : 1.0
                var e = (beat + dt * useBpm / 60.0 * rate) * 60.0 / useBpm
                if let l = length, l > 0 { e = min(max(e, 0), l) }
                return e
            }
        }
        if let e = resolvedElapsed { return e }
        if let p = beatProgress, let l = length, l > 0 { return p * l }
        return nil
    }
}

/// Un dispositivo StageLinq descubierto (p. ej. un Denon SC6000).
public final class StageLinqDevice: ObservableObject, Identifiable {
    public let id: String // "ip:puerto" del primer HOWDY (clave estable en UI)
    public let token: [UInt8]
    public let source: String
    public let name: String
    public let version: String
    /// Endpoint vivo: puede cambiar Wi‑Fi ↔ Ethernet sin duplicar el token.
    public private(set) var ip: String
    public private(set) var port: UInt16

    @Published public var connectionState: ConnectionState = .discovered
    @Published public var errorMessage: String = ""
    @Published public var services: [String: UInt16] = [:]
    @Published public var masterTempo: Double = 0
    @Published public var playerNumber: Int = 0

    /// No @Published: se actualiza en cada HOWDY y no debe redibujar SwiftUI.
    public var lastSeen: Date = Date()

    public let decks: [DeckState] = (1...4).map { DeckState(id: $0) }

    public enum ConnectionState: Equatable {
        case discovered
        case connecting
        case connected
        case failed
    }

    public init(info: DiscoveryInfo) {
        self.id = "\(info.address):\(info.port)"
        self.token = info.token
        self.source = info.source
        self.name = info.name
        self.version = info.version
        self.ip = info.address
        self.port = info.port
    }

    /// Actualiza IP/puerto del HOWDY sin crear otra fila (mismo token).
    public func applyEndpoint(ip: String, port: UInt16) {
        if !ip.isEmpty { self.ip = ip }
        if port != 0 { self.port = port }
    }

    /// Solo el simulador STAGE CONNECT TEST (token o nombre exacto).
    /// `contains("SIM")` marcaría un SC6000 real (p. ej. "SIMON") como TEST:
    /// se saltaría el HOWDY unicast y `entries()` lo ocultaría.
    public var isDenonSimulator: Bool {
        if token == DenonSimulator.announcementToken { return true }
        return Self.isDenonSimulatorName(name)
    }

    /// Servicios auxiliares del SC6000 (no son el reproductor de cabina).
    public var isAuxiliaryStageLinq: Bool {
        let u = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if u.isEmpty { return false }
        if u == "OFFLINEANALYZER" || u.hasPrefix("OFFLINEANALYZER") { return true }
        if u == "FILETRANSFER" || u.hasPrefix("FILETRANSFER") { return true }
        if u == "BROADCAST" || u == "SYNCING" { return true }
        return false
    }

    /// Unidad de deck (SC6000 / JP…): no SIM y no servicio auxiliar.
    public var isDenonPlayerUnit: Bool {
        !isDenonSimulator && !isAuxiliaryStageLinq
    }

    public static func isDenonSimulatorName(_ raw: String) -> Bool {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if u.isEmpty { return false }
        // Exacto. `contains("SIM")` / `hasPrefix("SC6000-SIM")` marcarían
        // un SC6000 real llamado p. ej. «SC6000-SIMON».
        if u == "SC6000-SIM" || u == "SC6000 TEST" || u == "SC6000TEST" { return true }
        if u == "STAGE CONNECT TEST" { return true }
        return false
    }
}
