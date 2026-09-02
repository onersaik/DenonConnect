// BeatInfoService.swift
// Servicio BeatInfo: posición de beat en tiempo real por deck, útil para
// sincronizar visuales (Resolume, ShowKontrol, etc.) al ritmo exacto.

import Foundation

public struct DeckBeatData {
    public var beat: Double
    public var totalBeats: Double
    public var bpm: Double
    public var samples: Double?
}

public struct BeatData {
    public var clock: UInt64
    public var decks: [DeckBeatData] // índice 0 = Deck1, ... según deckCount
}

public final class BeatInfoService: ServiceConnection {
    public init(host: String, port: UInt16, log: @escaping (String) -> Void = { _ in }) {
        super.init(host: host, port: port, serviceName: "BeatInfo", log: log)
    }

    public func run(onBeat: @escaping (BeatData) -> Void) throws {
        let c = try connectAndHandshake()
        log("BeatInfo conectado")

        // Mensaje de suscripción: 8 bytes fijos, SIN prefijo de longitud
        // (así lo hace la librería de referencia para este mensaje concreto).
        let sub: [UInt8] = [0x0, 0x0, 0x0, 0x4, 0x0, 0x0, 0x0, 0x0]
        try c.send(Data(sub))

        try readLoop { [weak self] payload in
            self?.handlePayload(payload, onBeat: onBeat)
        }
    }

    private func handlePayload(_ payload: Data, onBeat: (BeatData) -> Void) {
        guard payload.count >= 16 else { return }
        let r = ByteReader(payload)
        do {
            _ = try r.readUInt32() // id
            let clock = try r.readUInt64()
            let deckCount = Int(try r.readUInt32())
            guard deckCount > 0 && deckCount <= 8 else { return }

            var decks: [DeckBeatData] = []
            decks.reserveCapacity(deckCount)
            for _ in 0..<deckCount {
                let beat = try r.readFloat64()
                let total = try r.readFloat64()
                let bpm = try r.readFloat64()
                decks.append(DeckBeatData(beat: beat, totalBeats: total, bpm: bpm, samples: nil))
            }
            for i in 0..<deckCount {
                if r.remaining >= 8 {
                    decks[i].samples = try r.readFloat64()
                }
            }
            onBeat(BeatData(clock: clock, decks: decks))
        } catch {
            // Mensaje corto o inesperado: lo ignoramos, el siguiente debería venir bien.
        }
    }
}
