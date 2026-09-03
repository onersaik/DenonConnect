// SyncSnapshot.swift
// Foto del reloj musical que se envía al exterior (Resolume, SMPTE…).
// La produce la app a partir del deck que manda: el marcado como master y,
// si no hay ninguno, el primero que esté sonando.

import Foundation

public struct SyncSnapshot {
    public var bpm: Double
    public var beatInBar: Int      // 1…4, 0 si no se conoce
    public var beatCount: Int      // beat absoluto dentro de la pista
    public var playhead: Double?   // segundos; nil si el protocolo no lo da
    public var isPlaying: Bool
    public var sourceLabel:  String
    public var trackTitle:   String?   // nil si el protocolo no lo da
    public var trackArtist:  String?
    public var trackKey:    String?
    public var sourceDeckID: String?   // id estable de la fila (denon-…, pioneer-…)
    public var isMaster:     Bool
    public var isOnAir:      Bool
    /// Pitch/vari-speed REAL reportado por el protocolo (1.0 = normal).
    /// nil si no hay dato (p. ej. el simulador TestLink). Fuente directa y
    /// fiable para la velocidad del tono LTC -- ver LTCGenerator.applyPlayhead.
    public var playbackSpeed: Double?

    public init(bpm: Double, beatInBar: Int, beatCount: Int, playhead: Double?,
                isPlaying: Bool, sourceLabel: String,
                trackTitle: String? = nil, trackArtist: String? = nil,
                trackKey: String? = nil,
                sourceDeckID: String? = nil, isMaster: Bool = false, isOnAir: Bool = false,
                playbackSpeed: Double? = nil) {
        self.bpm           = bpm
        self.beatInBar     = beatInBar
        self.beatCount     = beatCount
        self.playhead      = playhead
        self.isPlaying     = isPlaying
        self.sourceLabel   = sourceLabel
        self.trackTitle    = trackTitle
        self.trackArtist   = trackArtist
        self.trackKey     = trackKey
        self.sourceDeckID  = sourceDeckID
        self.isMaster      = isMaster
        self.isOnAir       = isOnAir
        self.playbackSpeed = playbackSpeed
    }

    public static let idle = SyncSnapshot(bpm: 0, beatInBar: 0, beatCount: 0, playhead: nil, isPlaying: false, sourceLabel: "—")
}
