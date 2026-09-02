// OutputController.swift
// Coordina todas las salidas: OSC (Resolume), SMPTE LTC (audio),
// MIDI Timecode (MTC), servidor web de monitorización e historial de reproducción.
// Tick a 20 Hz para mantener sincronía de timecode.

import Foundation
import Combine
import CoreAudio
import StageLinqKit

// MARK: - Entrada de historial

struct PlaylistEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let title: String
    let artist: String
    let source: String

    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }
}

// MARK: - OutputController

final class OutputController: ObservableObject {

    // MARK: Resolume OSC
    @Published var resolumeEnabled    = false
    @Published var resolumeHost       = "127.0.0.1"
    @Published var resolumePort       = "7000"
    @Published var resolumeTempoMode: ResolumeBridge.TempoMode = .value
    @Published var resolumeResync     = true

    // MARK: SMPTE LTC
    @Published var ltcEnabled         = false
    @Published var ltcFrameRate: LTCGenerator.FrameRate = .fps25
    @Published var ltcTimecode        = "00:00:00:00"
    @Published var ltcError: String   = ""
    @Published var ltcDevices: [AudioDeviceInfo] = []
    @Published var ltcSelectedDeviceID: AudioDeviceID = 0
    @Published var ltcSourceDeckID: String? = nil
    @Published var ltcAutoFollow: Bool = true

    // MARK: MIDI Timecode (MTC)
    @Published var mtcEnabled         = false
    @Published var mtcFrameRate: MIDITimecodeGenerator.FrameRate = .fps25
    @Published var mtcError: String   = ""

    // MARK: Servidor Web
    @Published var webEnabled         = false
    @Published var webPort: String    = "8080"
    @Published var webError: String   = ""

    // MARK: Reloj
    @Published var clockSource        = "—"
    @Published var clockBPM: Double   = 0

    // MARK: Historial
    @Published var playlistHistory: [PlaylistEntry] = []
    private var lastTrackedID: String = ""

    // MARK: Privado
    private var bridge:  ResolumeBridge?
    private var ltc:     LTCGenerator?
    private var mtc:     MIDITimecodeGenerator?
    private var web:     WebServer?
    private var timer:   Timer?

    private weak var stageLinq:  StageLinqManager?
    private weak var proDJLink:  ProDJLinkManager?
    private var logSink: ((String) -> Void)?

    // MARK: Inicio

    func attach(stageLinq: StageLinqManager, proDJLink: ProDJLinkManager) {
        self.stageLinq = stageLinq
        self.proDJLink = proDJLink
        self.logSink   = { [weak stageLinq] msg in stageLinq?.log(msg) }
        ltcDevices     = LTCGenerator.availableOutputDevices()

        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    // MARK: LTC fuente por deck

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
        bridge.tempoMode          = resolumeTempoMode
        bridge.sendResyncOnDownbeat = resolumeResync
        bridge.update(host: resolumeHost, port: UInt16(resolumePort) ?? 7000)
    }

    // MARK: SMPTE LTC

    func refreshLTCDevices() { ltcDevices = LTCGenerator.availableOutputDevices() }

    func toggleLTC() {
        if ltcEnabled {
            ltc?.stop(); ltc = nil; ltcEnabled = false; ltcError = ""
        } else {
            let gen = LTCGenerator(log: { [weak self] in self?.logSink?($0) })
            gen.frameRate    = ltcFrameRate
            gen.outputDeviceID = ltcSelectedDeviceID == 0 ? nil : ltcSelectedDeviceID
            do {
                try gen.start()
                ltc = gen; ltcEnabled = true; ltcError = ""
            } catch {
                ltcError = "\(error)"
                logSink?("[SMPTE LTC] Error: \(error)")
            }
        }
    }

    // MARK: MTC

    func toggleMTC() {
        if mtcEnabled {
            mtc?.stop(); mtc = nil; mtcEnabled = false; mtcError = ""
        } else {
            let gen = MIDITimecodeGenerator(log: { [weak self] in self?.logSink?($0) })
            gen.frameRate = mtcFrameRate
            do {
                try gen.start()
                mtc = gen; mtcEnabled = true; mtcError = ""
            } catch {
                mtcError = "\(error)"
                logSink?("[MTC] Error: \(error)")
            }
        }
    }

    // MARK: Servidor Web

    func toggleWebServer() {
        if webEnabled {
            web?.stop(); web = nil; webEnabled = false; webError = ""
        } else {
            let port = UInt16(webPort) ?? 8080
            let srv = WebServer(log: { [weak self] in self?.logSink?($0) })
            srv.port = port
            srv.stateProvider = { [weak self] in self?.currentDeckSnapshots() ?? [] }
            do {
                try srv.start()
                web = srv; webEnabled = true; webError = ""
            } catch {
                webError = "\(error)"
                logSink?("[Web] Error al iniciar: \(error)")
            }
        }
    }

    // MARK: Historial

    func clearHistory() { playlistHistory.removeAll() }

    func exportHistoryCSV() -> String {
        var lines = ["Hora,Artista,Titulo,Fuente"]
        for entry in playlistHistory {
            let artist = entry.artist.replacingOccurrences(of: "\"", with: "\"\"")
            let title  = entry.title.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(entry.formattedTime),\"\(artist)\",\"\(title)\",\(entry.source)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Tick 20 Hz

    private func tick() {
        let masterSnapshot = currentSnapshot()

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

        if let mtc {
            if let playhead = ltcSnapshot.playhead, ltcSnapshot.isPlaying {
                if abs(mtc.currentPositionSeconds() - playhead) > 0.15 {
                    mtc.seek(toSeconds: playhead)
                }
            }
        }

        trackHistoryIfNeeded(snapshot: masterSnapshot)
    }

    // MARK: Seguimiento de historial

    private func trackHistoryIfNeeded(snapshot: SyncSnapshot) {
        guard snapshot.isPlaying, !snapshot.sourceLabel.isEmpty else { return }
        // Solo registrar cuando cambia la pista (identidad por sourceLabel+trackTitle)
        let trackKey = snapshot.sourceLabel + "|" + (snapshot.trackTitle ?? "")
        guard trackKey != lastTrackedID, !(snapshot.trackTitle ?? "").isEmpty else { return }
        lastTrackedID = trackKey
        let entry = PlaylistEntry(
            id: UUID(),
            timestamp: Date(),
            title: snapshot.trackTitle ?? "",
            artist: snapshot.trackArtist ?? "",
            source: snapshot.sourceLabel
        )
        DispatchQueue.main.async { [weak self] in
            self?.playlistHistory.insert(entry, at: 0)
        }
    }

    // MARK: DeckSnapshots para el servidor web

    private func currentDeckSnapshots() -> [DeckSnapshot] {
        var result: [DeckSnapshot] = []
        if let sl = stageLinq {
            for device in sl.devices {
                for deck in device.decks where deck.songLoaded {
                    let layer = deck.id == 1 ? "A" : (deck.id == 2 ? "B" : "\(deck.id)")
                    let name  = device.name.isEmpty ? device.ip : device.name
                    let prog  = deck.beatProgress
                    let elapsed: Double? = prog.map { $0 * deck.trackLength }
                    result.append(DeckSnapshot(
                        label:     "SC6000 \(name) \(layer)",
                        title:     deck.trackTitle,
                        artist:    deck.trackArtist,
                        bpm:       deck.bpm,
                        isPlaying: deck.playState == .playing,
                        isMaster:  deck.isMaster,
                        elapsed:   elapsed,
                        duration:  deck.trackLength > 0 ? deck.trackLength : nil,
                        progress:  prog,
                        beatInBar: Int(deck.currentBeat.truncatingRemainder(dividingBy: 4)) + 1
                    ))
                }
            }
        }
        if let pdl = proDJLink {
            for device in pdl.devices {
                result.append(DeckSnapshot(
                    label:     "\(device.model.isEmpty ? "CDJ" : device.model) P\(device.playerNumber)",
                    title:     device.trackLoaded ? "Pista #\(device.trackID)" : "",
                    artist:    "",
                    bpm:       device.effectiveBPM,
                    isPlaying: device.isPlaying,
                    isMaster:  device.isMaster,
                    elapsed:   device.hasPosition ? device.playhead : nil,
                    duration:  device.hasPosition && device.trackLength > 0 ? device.trackLength : nil,
                    progress:  device.hasPosition ? device.progress : nil,
                    beatInBar: device.beatInBar
                ))
            }
        }
        return result
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
                            playhead:  deck.beatProgress.map { $0 * deck.trackLength },
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
                        playhead:  device.hasPosition ? device.playhead : nil,
                        isPlaying: device.isPlaying,
                        sourceLabel: "CDJ player \(device.playerNumber)"
                    )
                }
            }
        }
        return nil
    }

    // MARK: Master snapshot

    private func currentSnapshot() -> SyncSnapshot {
        var onAirFallback:  SyncSnapshot?
        var playingFallback: SyncSnapshot?

        if let sl = stageLinq {
            for device in sl.devices {
                for deck in device.decks where deck.songLoaded {
                    let b = Int(deck.currentBeat)
                    let snap = SyncSnapshot(
                        bpm: deck.bpm,
                        beatInBar: b > 0 ? (b % 4) + 1 : 0,
                        beatCount: b,
                        playhead:  deck.beatProgress.map { $0 * deck.trackLength },
                        isPlaying: deck.playState == .playing,
                        sourceLabel: "Denon deck \(deck.id)",
                        trackTitle:  deck.trackTitle.isEmpty ? nil : deck.trackTitle,
                        trackArtist: deck.trackArtist.isEmpty ? nil : deck.trackArtist
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
                    playhead:  device.hasPosition ? device.playhead : nil,
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
