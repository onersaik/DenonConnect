// OutputController.swift
// Coordina las salidas hacia otras aplicaciones: OSC a Resolume y SMPTE LTC
// por audio. Toma 20 veces por segundo una foto del reloj musical del deck
// que manda y se la pasa a cada salida activa.

import Foundation
import Combine
import StageLinqKit

final class OutputController: ObservableObject {
    // Resolume
    @Published var resolumeEnabled = false
    @Published var resolumeHost = "127.0.0.1"
    @Published var resolumePort = "7000"
    @Published var resolumeTempoMode: ResolumeBridge.TempoMode = .value
    @Published var resolumeResync = true

    // SMPTE LTC
    @Published var ltcEnabled = false
    @Published var ltcFrameRate: LTCGenerator.FrameRate = .fps25
    @Published var ltcTimecode = "00:00:00:00"
    @Published var ltcError: String = ""

    // Estado mostrado
    @Published var clockSource = "—"
    @Published var clockBPM: Double = 0

    private var bridge: ResolumeBridge?
    private var ltc: LTCGenerator?
    private var timer: Timer?

    private weak var stageLinq: StageLinqManager?
    private weak var proDJLink: ProDJLinkManager?
    private var logSink: ((String) -> Void)?

    func attach(stageLinq: StageLinqManager, proDJLink: ProDJLinkManager) {
        self.stageLinq = stageLinq
        self.proDJLink = proDJLink
        self.logSink = { [weak stageLinq] message in stageLinq?.log(message) }

        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Resolume

    func toggleResolume() {
        if resolumeEnabled {
            bridge?.stop()
            bridge = nil
            resolumeEnabled = false
        } else {
            let port = UInt16(resolumePort) ?? 7000
            let bridge = ResolumeBridge(
                host: resolumeHost,
                port: port,
                tempoMode: resolumeTempoMode,
                sendResyncOnDownbeat: resolumeResync,
                log: { [weak self] in self?.logSink?($0) }
            )
            bridge.start()
            self.bridge = bridge
            resolumeEnabled = true
        }
    }

    func applyResolumeSettings() {
        guard let bridge else { return }
        bridge.tempoMode = resolumeTempoMode
        bridge.sendResyncOnDownbeat = resolumeResync
        bridge.update(host: resolumeHost, port: UInt16(resolumePort) ?? 7000)
    }

    // MARK: SMPTE

    func toggleLTC() {
        if ltcEnabled {
            ltc?.stop()
            ltc = nil
            ltcEnabled = false
            ltcError = ""
        } else {
            let generator = LTCGenerator(log: { [weak self] in self?.logSink?($0) })
            generator.frameRate = ltcFrameRate
            do {
                try generator.start()
                ltc = generator
                ltcEnabled = true
                ltcError = ""
            } catch {
                ltcError = "\(error)"
                logSink?("❌ SMPTE: \(error)")
            }
        }
    }

    // MARK: Reloj

    private func tick() {
        let snapshot = currentSnapshot()

        clockSource = snapshot.sourceLabel
        clockBPM = snapshot.bpm

        bridge?.send(snapshot)

        if let ltc {
            // Corregimos la deriva solo si se va de sitio de verdad: así el
            // timecode sale continuo en vez de dando saltos.
            if let playhead = snapshot.playhead, snapshot.isPlaying {
                if abs(ltc.currentPositionSeconds() - playhead) > 0.15 {
                    ltc.seek(toSeconds: playhead)
                }
            }
            ltcTimecode = ltc.currentTimecodeText()
        }
    }

    /// Elige el deck que manda: primero el marcado como master, y si no hay
    /// ninguno, el primero que esté sonando.
    private func currentSnapshot() -> SyncSnapshot {
        var playingFallback: SyncSnapshot?

        if let stageLinq {
            for device in stageLinq.devices {
                for deck in device.decks where deck.songLoaded {
                    let beatCount = Int(deck.currentBeat)
                    let snapshot = SyncSnapshot(
                        bpm: deck.bpm,
                        beatInBar: beatCount > 0 ? (beatCount % 4) + 1 : 0,
                        beatCount: beatCount,
                        playhead: deck.beatProgress.map { $0 * deck.trackLength },
                        isPlaying: deck.playState == .playing,
                        sourceLabel: "Denon deck \(deck.id)"
                    )
                    if deck.isMaster && snapshot.isPlaying { return snapshot }
                    if snapshot.isPlaying && playingFallback == nil { playingFallback = snapshot }
                }
            }
        }

        if let proDJLink {
            for device in proDJLink.devices {
                let snapshot = SyncSnapshot(
                    bpm: device.effectiveBPM,
                    beatInBar: device.beatInBar,
                    beatCount: device.beatCount,
                    playhead: device.hasPosition ? device.playhead : nil,
                    isPlaying: device.isPlaying,
                    sourceLabel: "CDJ player \(device.playerNumber)"
                )
                if device.isMaster && snapshot.isPlaying { return snapshot }
                if snapshot.isPlaying && playingFallback == nil { playingFallback = snapshot }
            }
        }

        return playingFallback ?? SyncSnapshot.idle
    }
}
