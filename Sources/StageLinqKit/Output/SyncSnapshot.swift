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
    public var sourceLabel: String

    public init(bpm: Double, beatInBar: Int, beatCount: Int, playhead: Double?, isPlaying: Bool, sourceLabel: String) {
        self.bpm = bpm
        self.beatInBar = beatInBar
        self.beatCount = beatCount
        self.playhead = playhead
        self.isPlaying = isPlaying
        self.sourceLabel = sourceLabel
    }

    public static let idle = SyncSnapshot(bpm: 0, beatInBar: 0, beatCount: 0, playhead: nil, isPlaying: false, sourceLabel: "—")
}
