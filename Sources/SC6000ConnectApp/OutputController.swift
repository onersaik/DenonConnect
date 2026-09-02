// OutputController.swift
// Coordina las salidas hacia otras aplicaciones: OSC a Resolume y SMPTE LTC
// por audio. Admite fuente LTC por deck específico o auto-follow al master/on-air.

import Foundation
import Combine
import CoreAudio
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
    @Published var ltcDevices: [AudioDeviceInfo] = []
    @Published var ltcSelectedDeviceID: AudioDeviceID = 0   // 0 = por defecto del sistema

    /// ID del deck (DeckDisplay.id) fijado como fuente LTC. nil = auto-follow master/on-air.
    @Published var ltcSourceDeckID: String? = nil
    @Published var ltcAutoFollow: Bool = true

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
        ltcDevices = LTCGenerator.availableOutputDevices()

        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    // MARK: LTC fuente por deck

    /// Fija el LTC a un deck concreto (nil = vuelve a auto-follow master/on-air).
    func setLTCSource(_ id: String?) {
        ltcSourceDeckID = id
        ltcAutoFollow   = (id == nil)
    }

    // MARK: Resolume

    func toggleResolume() {
        if resolumeEnabled {
            bridge?.stop(); bridge = nil; resolumeEnabled = false
        } else {
            let port = UInt16(resolumePort) ?? 7000
            let b = ResolumeBridge(
                host: resolumeHost, port: port,
                tempoMode: resolumeTempoMode,
                sendResyncOnDownbeat: resolumeResync,
                log: { [weak self] in self?.logSink?($0) }
            )
            b.start(); bridge = b; resolumeEnabled = true
        }
    }

    func applyResolumeSettings() {
        guard let bridge else { return }
        bridge.tempoMode = resolumeTempoMode
        bridge.sendResyncOnDownbeat = resolumeResync
        bridge.update(host: resolumeHost, port: UInt16(resolumePort) ?? 7000)
    }

    func refreshLTCDevices() {
        ltcDevices = LTCGenerator.availableOutputDevices()
    }

    // MARK: SMPTE

    func toggleLTC() {
        if ltcEnabled {
            ltc?.stop(); ltc = nil; ltcEnabled = false; ltcError = ""
        } else {
            let generator = LTCGenerator(log: { [weak self] in self?.logSink?($0) })
            generator.frameRate = ltcFrameRate
            generator.outputDeviceID = ltcSelectedDeviceID == 0 ? nil : ltcSelectedDeviceID
            do {
                try generator.start()
                ltc = generator; ltcEnabled = true; ltcError = ""
            } catch {
                ltcError = "\(error)"; logSink?("❌ SMPTE: \(error)")
            }
        }
    }

    // MARK: Tick 20 Hz

    private func tick() {
        let masterSnapshot = currentSnapshot()

        // LTC usa deck fijado si hay uno; si no, sigue al master
        let ltcSnapshot: SyncSnapshot
        if !ltcAutoFollow, let id = ltcSourceDeckID,
           let specific = snapshotForDeckID(id) {
            ltcSnapshot = specific
        } else {
            ltcSnapshot = masterSnapshot
        }

        clockSource = masterSnapshot.sourceLabel
        clockBPM    = masterSnapshot.bpm

        bridge?.send(masterSnapshot)

        if let ltc {
            if let playhead = ltcSnapshot.playhead, ltcSnapshot.isPlaying {
                if abs(ltc.currentPositionSeconds() - playhead) > 0.15 {
                    ltc.seek(toSeconds: playhead)
                }
            }
            ltcTimecode = ltc.currentTimecodeText()
        }
    }

    // MARK: Snapshot de deck específico

    private func snapshotForDeckID(_ id: String) -> SyncSnapshot? {
        if let sl = stageLinq {
            for device in sl.devices {
                for deck in device.decks {
                    if "denon-\(device.id)-\(deck.id)" == id {
                        let b = Int(deck.currentBeat)
                        return SyncSnapshot(
                            bpm: deck.bpm,
                            beatInBar: b > 0 ? (b % 4) + 1 : 0,
                            beatCount: b,
                            playhead: deck.beatProgress.map { $0 * deck.trackLength },
                            isPlaying: deck.playState == .playing,
                            sourceLabel: "Denon deck \(deck.id)"
                        )
                    }
                }
            }
        }
        if let pdl = proDJLink {
            for device in pdl.devices {
                if "pioneer-\(device.id)" == id {
                    return SyncSnapshot(
                        bpm: device.effectiveBPM,
                        beatInBar: device.beatInBar,
                        beatCount: device.beatCount,
                        playhead: device.hasPosition ? device.playhead : nil,
                        isPlaying: device.isPlaying,
                        sourceLabel: "CDJ player \(device.playerNumber)"
                    )
                }
            }
        }
        return nil
    }

    // MARK: Master snapshot (auto-follow)

    /// Elige el deck que manda: master+playing > on-air+playing > primer deck sonando.
    private func currentSnapshot() -> SyncSnapshot {
        var onAirFallback: SyncSnapshot?
        var playingFallback: SyncSnapshot?

        if let sl = stageLinq {
            for device in sl.devices {
                for deck in device.decks where deck.songLoaded {
                    let b = Int(deck.currentBeat)
                    let snap = SyncSnapshot(
                        bpm: deck.bpm,
                        beatInBar: b > 0 ? (b % 4) + 1 : 0,
                        beatCount: b,
                        playhead: deck.beatProgress.map { $0 * deck.trackLength },
                        isPlaying: deck.playState == .playing,
                        sourceLabel: "Denon deck \(deck.id)"
                    )
                    if deck.isMaster && snap.isPlaying { return snap }
                    if snap.isPlaying && playingFallback == nil { playingFallback = snap }
                }
            }
        }

        if let pdl = proDJLink {
            for device in pdl.devices {
                let snap = SyncSnapshot(
                    bpm: device.effectiveBPM,
                    beatInBar: device.beatInBar,
                    beatCount: device.beatCount,
                    playhead: device.hasPosition ? device.playhead : nil,
                    isPlaying: device.isPlaying,
                    sourceLabel: "CDJ player \(device.playerNumber)"
                )
                if device.isMaster && snap.isPlaying { return snap }
                if device.isOnAir && snap.isPlaying && onAirFallback == nil { onAirFallback = snap }
                if snap.isPlaying && playingFallback == nil { playingFallback = snap }
            }
        }

        return onAirFallback ?? playingFallback ?? SyncSnapshot.idle
    }
}
