// ResolumeBridge.swift
// Envía a Resolume el tempo y el pulso de los reproductores por OSC.
//
// Por qué OSC y no otra cosa: Resolume no acepta que un tercero se le conecte
// como si fuera un reproductor. Su soporte de StageLinq y Pro DJ Link es
// interno y escucha directamente a los equipos. Lo que sí expone oficialmente
// para control externo es OSC, así que ese es el camino correcto para que siga
// el tempo y el compás de los decks.
//
// En Resolume: Preferencias → OSC → activar entrada (puerto 7000 por defecto).

import Foundation

public final class ResolumeBridge {
    public enum TempoMode: String, CaseIterable {
        case value = "Valor de tempo"
        case tap = "Tap por beat"
    }

    private var client: OSCClient?
    private let log: (String) -> Void

    public private(set) var host: String
    public private(set) var port: UInt16
    public var tempoMode: TempoMode
    public var sendResyncOnDownbeat: Bool

    /// Direcciones OSC de Resolume. Se dejan configurables porque cambian
    /// entre versiones y cada instalación puede tenerlas mapeadas distinto.
    public var tempoAddress = "/composition/tempocontroller/tempo"
    public var tapAddress = "/composition/tempocontroller/tempotap"
    public var resyncAddress = "/composition/tempocontroller/resync"

    private var lastBPMSent: Double = 0
    private var lastBeatCount: Int = -1
    private var lastBeatInBar: Int = -1

    public init(host: String = "127.0.0.1",
                port: UInt16 = 7000,
                tempoMode: TempoMode = .value,
                sendResyncOnDownbeat: Bool = true,
                log: @escaping (String) -> Void = { _ in }) {
        self.host = host
        self.port = port
        self.tempoMode = tempoMode
        self.sendResyncOnDownbeat = sendResyncOnDownbeat
        self.log = log
    }

    public func start() {
        client = OSCClient(host: host, port: port)
        lastBPMSent = 0
        lastBeatCount = -1
        lastBeatInBar = -1
        log("🎨 Resolume: enviando OSC a \(host):\(port)")
    }

    public func stop() {
        client?.close()
        client = nil
        log("⏹ Resolume: envío OSC detenido")
    }

    public func update(host: String, port: UInt16) {
        self.host = host
        self.port = port
        if client != nil {
            stop()
            start()
        }
    }

    /// Se llama con cada foto del reloj musical. Solo envía cuando algo cambia,
    /// para no inundar a Resolume de mensajes idénticos.
    public func send(_ snapshot: SyncSnapshot) {
        guard let client else { return }
        guard snapshot.isPlaying, snapshot.bpm > 0 else { return }

        switch tempoMode {
        case .value:
            // Solo al cambiar el tempo de forma apreciable.
            if abs(snapshot.bpm - lastBPMSent) > 0.05 {
                client.send(tempoAddress, [.float(Float(snapshot.bpm))])
                lastBPMSent = snapshot.bpm
            }
        case .tap:
            // Un tap por beat: Resolume deduce el tempo del ritmo de los taps.
            if snapshot.beatCount != lastBeatCount {
                client.send(tapAddress, [.int(1)])
            }
        }

        // Resync en el primer tiempo del compás, para alinear la fase.
        if sendResyncOnDownbeat,
           snapshot.beatInBar == 1,
           snapshot.beatInBar != lastBeatInBar {
            client.send(resyncAddress, [.int(1)])
        }

        lastBeatCount = snapshot.beatCount
        lastBeatInBar = snapshot.beatInBar
    }
}
