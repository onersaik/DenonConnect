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
    @Published public var currentBeat: Double = 0
    @Published public var totalBeats: Double = 0
    @Published public var beatBpm: Double = 0
    @Published public var beatPulse: Bool = false // parpadeo visual en cada beat

    public init(id: Int) { self.id = id }

    /// Fracción de progreso 0...1 derivada del beat, cuando hay datos de BeatInfo.
    public var beatProgress: Double? {
        guard totalBeats > 0 else { return nil }
        return min(max(currentBeat / totalBeats, 0), 1)
    }
}

/// Un dispositivo StageLinq descubierto (p. ej. un Denon SC6000).
public final class StageLinqDevice: ObservableObject, Identifiable {
    public let id: String // "ip:puerto"
    public let token: [UInt8]
    public let source: String
    public let name: String
    public let version: String
    public let ip: String
    public let port: UInt16

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
}
