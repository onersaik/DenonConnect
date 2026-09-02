// OutputController.swift
// Coordina todas las salidas: OSC (Resolume), SMPTE LTC (audio),
// MIDI Timecode (MTC), servidor web de monitorización e historial de reproducción.
// Tick a 60 Hz para clavar el timecode al playhead de la pista.
//
// SMPTE: dos capas independientes.
//   MASTER — un LTC de casa que sigue al deck master / On Air / fader / el que suena.
//   POR DECK — un generador por fila, cada uno con su dispositivo CoreAudio.
// Apagar un botón hace stop() real: no pausa en 0, no re-arma el auto-follow.

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

/// Fila visible en CONFIG para asignar un LTC propio.
struct LTCDeckSlot: Identifiable, Equatable {
    let id: String
    let label: String
}

// MARK: - OutputController

final class OutputController: ObservableObject {

    // MARK: Resolume OSC
    @Published var resolumeEnabled    = false
    @Published var resolumeHost       = "127.0.0.1"
    @Published var resolumePort       = "7000"
    @Published var resolumeTempoMode: ResolumeBridge.TempoMode = .value
    @Published var resolumeResync     = true

    // MARK: SMPTE LTC — Master (una salida de casa)
    @Published var ltcEnabled         = false
    @Published var ltcFrameRate: LTCGenerator.FrameRate = .fps25
    @Published var ltcTimecode        = "00:00:00:00"
    @Published var ltcError: String   = ""
    @Published var ltcDevices: [AudioDeviceInfo] = []
    @Published var ltcSelectedDeviceID: AudioDeviceID = 0
    /// Si true, el Master salta al deck master / On Air / el que está sonando.
    /// Si false, se queda anclado al último deck seguido (no re-arma al apagar).
    @Published var ltcAutoFollow: Bool = true
    /// Deck al que el Master está anclado a mano. nil = auto (si ltcAutoFollow).
    @Published var ltcSourceDeckID: String? = nil
    /// Deck cuyo playhead está saliendo ahora por el LTC Master (LED / zoom).
    @Published var ltcFollowedDeckID: String? = nil
    /// Deck master / on-air / playing, aunque el LTC esté apagado (waveform zoom).
    @Published var hotDeckID: String? = nil

    // MARK: SMPTE LTC — por reproductor
    @Published var ltcDeckSlots: [LTCDeckSlot] = []
    @Published var ltcDeckEnabled: [String: Bool] = [:]
    @Published var ltcDeckDeviceID: [String: AudioDeviceID] = [:]
    @Published var ltcDeckTimecode: [String: String] = [:]
    @Published var ltcDeckError: [String: String] = [:]
    @Published var ltcDeviceWarning: String = ""

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
    private var deckLTC: [String: LTCGenerator] = [:]
    private var mtc:     MIDITimecodeGenerator?
    private var web:     WebServer?
    private var timer:   Timer?

    private weak var stageLinq:  StageLinqManager?
    private weak var proDJLink:  ProDJLinkManager?
    private weak var testLink:   TestLinkReceiver?
    private var logSink: ((String) -> Void)?

    var ltcAnyEnabled: Bool { ltcEnabled || deckLTC.contains { $0.value.isRunning } }

    // MARK: Inicio

    func attach(stageLinq: StageLinqManager, proDJLink: ProDJLinkManager, testLink: TestLinkReceiver? = nil) {
        self.stageLinq = stageLinq
        self.proDJLink = proDJLink
        self.testLink  = testLink
        self.logSink   = { [weak stageLinq] msg in stageLinq?.log(msg) }
        ltcDevices     = LTCGenerator.availableOutputDevices()

        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        stopMasterLTC(silent: true)
        stopAllDeckLTC()
        mtc?.stop(); mtc = nil; mtcEnabled = false
        bridge?.stop(); bridge = nil; resolumeEnabled = false
        web?.stop(); web = nil; webEnabled = false
    }

    deinit {
        timer?.invalidate()
        ltc?.stop()
        deckLTC.values.forEach { $0.stop() }
        mtc?.stop()
        bridge?.stop()
        web?.stop()
    }

    // MARK: Consultas de LED / fila

    /// Verde en la fila: ese deck está emitiendo (generador propio o Master siguiéndolo).
    func isRowLTCLit(_ id: String) -> Bool {
        if isDeckLTCEnabled(id) { return true }
        guard ltcEnabled, let followed = ltcFollowedDeckID else { return false }
        return Self.sameDeckID(followed, id)
    }

    func isDeckLTCEnabled(_ id: String) -> Bool {
        for (key, gen) in deckLTC {
            if Self.sameDeckID(key, id), gen.isRunning { return true }
        }
        for (key, on) in ltcDeckEnabled where on {
            if Self.sameDeckID(key, id) { return true }
        }
        return false
    }

    func isPinnedLTCSource(_ id: String) -> Bool { isRowLTCLit(id) }

    func isWaveformHot(_ id: String) -> Bool {
        guard let hot = hotDeckID else { return false }
        return Self.sameDeckID(hot, id)
    }

    // MARK: Clic en el botón SMPTE de una fila

    /// Dos capas, sin pelearse con el auto-follow:
    /// - Si esta fila tiene generador propio → lo para (stop real).
    /// - Si el Master está emitiendo esta fila → para el Master (no vuelve a auto).
    /// - Si no: arranca el generador de ESTA fila en su dispositivo asignado.
    func toggleRowLTC(_ id: String) {
        let key = canonicalDeckKey(id)
        if isDeckLTCEnabled(key) {
            stopDeckLTC(key)
            return
        }
        if ltcEnabled, let followed = ltcFollowedDeckID, Self.sameDeckID(followed, key) {
            stopMasterLTC()
            return
        }
        startDeckLTC(key)
    }

    /// Compatibilidad con llamadas antiguas.
    func armLTC(fromDeckID id: String) { toggleRowLTC(id) }

    func setLTCSource(_ id: String?) {
        ltcSourceDeckID = id
        ltcAutoFollow = (id == nil)
    }

    /// Ancla el Master a esta fila (cancela auto). No toca los generadores por deck.
    func pinMaster(to id: String) {
        ltcSourceDeckID = id
        ltcAutoFollow = false
        if !ltcEnabled {
            startMasterLTC()
        } else {
            applyToMaster(snapshotForDeckID(id))
        }
    }

    func enableMasterAutoFollow() {
        setAutoFollow(true)
        if !ltcEnabled { startMasterLTC() }
    }

    func setAutoFollow(_ on: Bool) {
        ltcAutoFollow = on
        if on {
            ltcSourceDeckID = nil
        } else if ltcSourceDeckID == nil {
            ltcSourceDeckID = ltcFollowedDeckID ?? hotDeckID
        }
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

    // MARK: SMPTE LTC — Master

    func refreshLTCDevices() { ltcDevices = LTCGenerator.availableOutputDevices() }

    func toggleLTC() {
        if ltcEnabled { stopMasterLTC() } else { startMasterLTC() }
    }

    func startMasterLTC() {
        stopMasterLTC(silent: true)
        ltcError = ""
        let deviceID = ltcSelectedDeviceID
        if let owner = deviceOwner(deviceID, excluding: "master") {
            ltcError = "El dispositivo ya lo usa \(owner). Dos LTC en el mismo canal se pisan."
            ltcDeviceWarning = ltcError
            return
        }
        let snap = snapshotForMaster()
        do {
            let gen = makeGenerator(name: "Master", deviceID: deviceID, snap: snap)
            try gen.start()
            applyPlayhead(gen, snap)
            ltc = gen
            ltcEnabled = true
            ltcFollowedDeckID = snap.sourceDeckID
            ltcTimecode = Self.timecode(snap, fps: ltcFrameRate)
            refreshDeviceWarning()
            logSink?("[SMPTE] Master ON — \(snap.sourceLabel)")
        } catch {
            ltcError = "\(error)"
            logSink?("[SMPTE LTC] Master error: \(error)")
        }
    }

    func stopMasterLTC(silent: Bool = false) {
        ltc?.setPaused(true)
        ltc?.stop()
        ltc = nil
        ltcEnabled = false
        ltcError = ""
        ltcFollowedDeckID = nil
        ltcTimecode = "00:00:00:00"
        // No reactivar auto-follow: el usuario acaba de apagar.
        // MTC acoplado al mismo reloj: se congela (el toggle MTC sigue siendo independiente).
        mtc?.setPaused(true)
        refreshDeviceWarning()
        if !silent { logSink?("[SMPTE] Master OFF") }
    }

    func applyMasterDeviceChange() {
        guard ltcEnabled else { return }
        startMasterLTC()
    }

    func applyMasterFrameRateChange() {
        guard ltcEnabled else { return }
        startMasterLTC()
        if mtcEnabled { restartMTC() }
    }

    // MARK: SMPTE LTC — por deck

    func startDeckLTC(_ id: String) {
        let key = generatorKey(for: id)
        stopDeckLTC(key, silent: true)
        ltcDeckError[key] = nil
        let deviceID = ltcDeckDeviceID[key] ?? 0
        if let owner = deviceOwner(deviceID, excluding: key) {
            let msg = "El dispositivo ya lo usa \(owner). Elige otra salida."
            ltcDeckError[key] = msg
            ltcDeckEnabled[key] = false
            ltcDeviceWarning = msg
            logSink?("[SMPTE] \(key): \(msg)")
            return
        }
        let snap = snapshotForDeckID(key) ?? snapshotForDeckID(id)
        do {
            let label = ltcDeckSlots.first { Self.sameDeckID($0.id, key) }?.label ?? key
            let gen = makeGenerator(name: label, deviceID: deviceID, snap: snap)
            try gen.start()
            applyPlayhead(gen, snap)
            deckLTC[key] = gen
            ltcDeckEnabled[key] = true
            ltcDeckTimecode[key] = Self.timecode(snap, fps: ltcFrameRate)
            refreshDeviceWarning()
            logSink?("[SMPTE] Deck ON \(label)")
        } catch {
            ltcDeckError[key] = "\(error)"
            ltcDeckEnabled[key] = false
            logSink?("[SMPTE LTC] Deck \(key) error: \(error)")
        }
    }

    func stopDeckLTC(_ id: String, silent: Bool = false) {
        var keys = Set(deckLTC.keys.filter { Self.sameDeckID($0, id) })
        keys.formUnion(ltcDeckEnabled.keys.filter { Self.sameDeckID($0, id) })
        keys.insert(generatorKey(for: id))
        for key in keys {
            if let gen = deckLTC[key] {
                gen.setPaused(true)
                gen.stop()
            }
            deckLTC[key] = nil
            ltcDeckEnabled[key] = false
            ltcDeckTimecode[key] = "00:00:00:00"
            ltcDeckError[key] = nil
        }
        refreshDeviceWarning()
        if !silent { logSink?("[SMPTE] Deck OFF \(id)") }
    }

    func setDeckLTCEnabled(_ id: String, enabled: Bool) {
        if enabled { startDeckLTC(id) } else { stopDeckLTC(id) }
    }

    func setDeckDevice(_ id: String, deviceID: AudioDeviceID) {
        let key = generatorKey(for: id)
        ltcDeckDeviceID[key] = deviceID
        if isDeckLTCEnabled(key) {
            startDeckLTC(key)
        } else {
            refreshDeviceWarning()
        }
    }

    func deckDeviceBinding(_ id: String) -> AudioDeviceID {
        ltcDeckDeviceID[generatorKey(for: id)] ?? 0
    }

    private func generatorKey(for id: String) -> String {
        if let existing = deckLTC.keys.first(where: { Self.sameDeckID($0, id) }) {
            return existing
        }
        if let slot = ltcDeckSlots.first(where: { Self.sameDeckID($0.id, id) }) {
            return slot.id
        }
        return id
    }

    private func stopAllDeckLTC() {
        for key in Array(deckLTC.keys) {
            stopDeckLTC(key, silent: true)
        }
    }

    // MARK: MTC

    func toggleMTC() {
        if mtcEnabled {
            mtc?.stop(); mtc = nil; mtcEnabled = false; mtcError = ""
        } else {
            restartMTC()
        }
    }

    private func restartMTC() {
        mtc?.stop(); mtc = nil
        let gen = MIDITimecodeGenerator(log: { [weak self] in self?.logSink?($0) })
        gen.frameRate = mtcFrameRate
        do {
            let snap = snapshotForMaster()
            if let playhead = snap.playhead, playhead.isFinite, playhead >= 0 {
                gen.applyPlayhead(seconds: playhead, playing: false)
            }
            try gen.start()
            mtc = gen; mtcEnabled = true; mtcError = ""
            applyPlayhead(mtc: gen, snap)
        } catch {
            mtcError = "\(error)"
            mtcEnabled = false
            logSink?("[MTC] Error: \(error)")
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

    // MARK: Tick 60 Hz

    private func tick() {
        refreshDeckSlots()

        let masterSnapshot = currentSnapshot()
        hotDeckID = masterSnapshot.sourceDeckID

        bridge?.send(masterSnapshot)

        if ltcEnabled {
            let snap = snapshotForMaster()
            clockSource = snap.sourceLabel
            clockBPM    = snap.bpm
            applyToMaster(snap)
            ltcFollowedDeckID = snap.sourceDeckID
            ltcTimecode = Self.timecode(snap, fps: ltcFrameRate)
        } else {
            ltcFollowedDeckID = nil
            clockSource = masterSnapshot.sourceLabel
            clockBPM    = masterSnapshot.bpm
        }

        for (key, gen) in deckLTC {
            guard gen.isRunning else { continue }
            let snap = snapshotForDeckID(key)
            applyPlayhead(gen, snap)
            ltcDeckTimecode[key] = Self.timecode(snap, fps: ltcFrameRate)
        }

        if mtcEnabled, let mtc {
            let snap = ltcEnabled ? snapshotForMaster() : masterSnapshot
            applyPlayhead(mtc: mtc, snap)
        }

        trackHistoryIfNeeded(snapshot: masterSnapshot)
    }

    // MARK: Generadores

    private func makeGenerator(name: String, deviceID: AudioDeviceID, snap: SyncSnapshot?) -> LTCGenerator {
        let gen = LTCGenerator(name: name, log: { [weak self] in self?.logSink?($0) })
        gen.frameRate = ltcFrameRate
        gen.outputDeviceID = deviceID == 0 ? nil : deviceID
        if let playhead = snap?.playhead, playhead.isFinite, playhead >= 0 {
            gen.applyPlayhead(seconds: playhead, playing: false)
        }
        return gen
    }

    private func applyToMaster(_ snap: SyncSnapshot?) {
        applyPlayhead(ltc, snap)
    }

    private func applyPlayhead(_ gen: LTCGenerator?, _ snap: SyncSnapshot?) {
        guard let gen else { return }
        guard let snap else {
            gen.setPaused(true)
            return
        }
        guard let playhead = snap.playhead, playhead.isFinite, playhead >= 0 else {
            gen.setPaused(true)
            return
        }
        gen.applyPlayhead(seconds: playhead, playing: snap.isPlaying)
    }

    private func applyPlayhead(mtc gen: MIDITimecodeGenerator, _ snap: SyncSnapshot?) {
        guard let snap else {
            gen.setPaused(true)
            return
        }
        guard let playhead = snap.playhead, playhead.isFinite, playhead >= 0 else {
            gen.setPaused(true)
            return
        }
        gen.applyPlayhead(seconds: playhead, playing: snap.isPlaying)
    }

    private static func timecode(_ snap: SyncSnapshot?, fps: LTCGenerator.FrameRate) -> String {
        guard let playhead = snap?.playhead, playhead.isFinite, playhead >= 0 else {
            return "00:00:00:00"
        }
        return LTCGenerator.timecodeText(seconds: playhead, fps: fps.rawValue)
    }

    // MARK: Conflictos de dispositivo

    /// Quién ocupa ya este dispositivo (Master o un deck). nil = libre.
    func deviceOwner(_ deviceID: AudioDeviceID, excluding slot: String) -> String? {
        let want = resolvedDeviceID(deviceID)
        if ltcEnabled, slot != "master" {
            if resolvedDeviceID(ltcSelectedDeviceID) == want {
                return "LTC Master"
            }
        }
        for (key, gen) in deckLTC where gen.isRunning {
            if Self.sameDeckID(key, slot) { continue }
            let other = resolvedDeviceID(ltcDeckDeviceID[key] ?? 0)
            if other == want {
                let label = ltcDeckSlots.first { Self.sameDeckID($0.id, key) }?.label ?? key
                return label
            }
        }
        return nil
    }

    private func resolvedDeviceID(_ id: AudioDeviceID) -> AudioDeviceID {
        if id != 0 { return id }
        if let def = ltcDevices.first(where: { $0.isDefault && $0.id != 0 }) {
            return def.id
        }
        return 0
    }

    private func refreshDeviceWarning() {
        var seen: [AudioDeviceID: String] = [:]
        func note(_ deviceID: AudioDeviceID, label: String) {
            let rid = resolvedDeviceID(deviceID)
            if let prev = seen[rid] {
                ltcDeviceWarning = "\(prev) y \(label) comparten el mismo dispositivo: los timecodes se pisan. Asigna salidas distintas (BlackHole, Loopback o una interfaz)."
                return
            }
            seen[rid] = label
        }
        ltcDeviceWarning = ""
        if ltcEnabled { note(ltcSelectedDeviceID, label: "Master") }
        for (key, gen) in deckLTC where gen.isRunning {
            let label = ltcDeckSlots.first { Self.sameDeckID($0.id, key) }?.label ?? key
            note(ltcDeckDeviceID[key] ?? 0, label: label)
            if !ltcDeviceWarning.isEmpty { return }
        }
    }

    // MARK: Slots visibles (CONFIG)

    private func refreshDeckSlots() {
        let slots = listVisibleDeckSlots()
        if slots != ltcDeckSlots {
            ltcDeckSlots = slots
        }
        let live = Set(slots.map(\.id))
        for key in Array(deckLTC.keys) {
            let stillVisible = live.contains(where: { Self.sameDeckID($0, key) })
            if !stillVisible {
                stopDeckLTC(key)
            }
        }
    }

    private func listVisibleDeckSlots() -> [LTCDeckSlot] {
        var slots: [LTCDeckSlot] = []
        var used = Set<String>()

        func add(_ id: String, _ label: String) {
            let key = canonicalDeckKey(id)
            guard used.insert(key).inserted else { return }
            slots.append(LTCDeckSlot(id: key, label: label))
        }

        if let sl = stageLinq {
            let denonOn = testLink?.roster.denonOn == true
            for device in sl.devices {
                for deck in device.decks {
                    let overlay = denonOn ? testLink?.snapshot?.deck(deck.id - 1) : nil
                    let title = TrackNaming.cleanTitle(overlay?.title ?? deck.trackTitle)
                    let loaded = overlay?.loaded ?? (deck.songLoaded && !title.isEmpty)
                    guard loaded else { continue }
                    let layer = deck.id == 1 ? "A" : (deck.id == 2 ? "B" : "\(deck.id)")
                    let name = device.name.isEmpty ? device.ip : device.name
                    let id = overlay != nil
                        ? DeckDisplayBuilder.testDenonID(deck.id - 1)
                        : "denon-\(device.id)-\(deck.id)"
                    add(id, "SC6000 \(name) \(layer)")
                }
            }
        }
        if testLink?.roster.denonOn == true {
            if testLink?.roster.layerLoaded(0) == true { add(DeckDisplayBuilder.testDenonID(0), "SC6000 TEST A") }
            if testLink?.roster.layerLoaded(1) == true { add(DeckDisplayBuilder.testDenonID(1), "SC6000 TEST B") }
        }
        if testLink?.roster.hasPioneerTrack == true {
            add(DeckDisplayBuilder.testPioneerID, "CDJ-3000 TEST")
        }
        if let pdl = proDJLink {
            for device in pdl.devices {
                if !shouldUsePioneer(device) { continue }
                add("pioneer-\(device.id)", "\(device.model.isEmpty ? "CDJ" : device.model) P\(device.playerNumber)")
            }
        }
        return slots
    }

    private func canonicalDeckKey(_ id: String) -> String {
        if let slot = ltcDeckSlots.first(where: { Self.sameDeckID($0.id, id) }) {
            return slot.id
        }
        return id
    }

    // MARK: Seguimiento de historial

    private func trackHistoryIfNeeded(snapshot: SyncSnapshot) {
        guard snapshot.isPlaying, !snapshot.sourceLabel.isEmpty else { return }
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
            let denonOn = testLink?.roster.denonOn == true
            for device in sl.devices {
                for deck in device.decks where deck.songLoaded && !deck.trackTitle.isEmpty {
                    let overlay = denonOn ? testLink?.snapshot?.deck(deck.id - 1) : nil
                    let bpm = MusicalClock.bpm(overlay?.bpm ?? 0, deck.bpm, deck.beatBpm)
                    let layer = deck.id == 1 ? "A" : (deck.id == 2 ? "B" : "\(deck.id)")
                    let name  = device.name.isEmpty ? device.ip : device.name
                    let prog  = overlay?.progress ?? deck.beatProgress
                    let elapsed: Double? = overlay?.position ?? prog.map { $0 * deck.trackLength }
                    result.append(DeckSnapshot(
                        label:     "SC6000 \(name) \(layer)",
                        title:     TrackNaming.cleanTitle(overlay?.title ?? deck.trackTitle),
                        artist:    overlay?.artist ?? deck.trackArtist,
                        bpm:       bpm,
                        isPlaying: overlay?.playing ?? (deck.playState == .playing),
                        isMaster:  overlay?.isMaster ?? deck.isMaster,
                        elapsed:   elapsed,
                        duration:  overlay?.duration ?? (deck.trackLength > 0 ? deck.trackLength : nil),
                        progress:  prog,
                        beatInBar: overlay != nil
                            ? MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm)
                            : Int(deck.currentBeat.truncatingRemainder(dividingBy: 4)) + 1
                    ))
                }
            }
        }
        if let overlay = pioneerTestOverlay() {
            let snap = makeTestLinkSyncSnapshot(overlay, label: "CDJ-3000 TEST",
                                                id: DeckDisplayBuilder.testPioneerID,
                                                isMaster: overlay.playing)
            result.append(DeckSnapshot(
                label:     "CDJ-3000 TEST",
                title:     snap.trackTitle ?? "",
                artist:    snap.trackArtist ?? "",
                bpm:       snap.bpm,
                isPlaying: snap.isPlaying,
                isMaster:  overlay.playing,
                elapsed:   snap.playhead,
                duration:  overlay.duration > 0 ? overlay.duration : nil,
                progress:  overlay.progress,
                beatInBar: snap.beatInBar
            ))
        }
        if let overlay = denonTestOverlay(layer: 0), stageLinqHasNoLayer(0) {
            result.append(testDeckSnapshot(overlay, label: "SC6000 TEST A", master: overlay.isMaster || overlay.playing))
        }
        if let overlay = denonTestOverlay(layer: 1), stageLinqHasNoLayer(1) {
            result.append(testDeckSnapshot(overlay, label: "SC6000 TEST B", master: overlay.isMaster))
        }
        if let pdl = proDJLink {
            for device in pdl.devices {
                if !shouldUsePioneer(device) { continue }
                let bpm = MusicalClock.bpm(device.effectiveBPM, device.trackBPM)
                result.append(DeckSnapshot(
                    label:     "\(device.model.isEmpty ? "CDJ" : device.model) P\(device.playerNumber)",
                    title:     "",
                    artist:    "",
                    bpm:       bpm,
                    isPlaying: device.isPlaying,
                    isMaster:  device.isMaster,
                    elapsed:   device.hasPosition ? device.playhead : nil,
                    duration:  device.hasPosition && device.trackLength > 0 ? device.trackLength : nil,
                    progress:  device.hasPosition && device.trackLength > 0 ? device.progress : nil,
                    beatInBar: device.beatInBar
                ))
            }
        }
        return result
    }

    private func testDeckSnapshot(_ overlay: TestLinkDeck, label: String, master: Bool) -> DeckSnapshot {
        let bpm = MusicalClock.bpm(overlay.bpm)
        return DeckSnapshot(
            label:     label,
            title:     TrackNaming.cleanTitle(overlay.title),
            artist:    overlay.artist,
            bpm:       bpm,
            isPlaying: overlay.playing,
            isMaster:  master,
            elapsed:   overlay.position,
            duration:  overlay.duration > 0 ? overlay.duration : nil,
            progress:  overlay.progress,
            beatInBar: MusicalClock.beatInBar(position: overlay.position, bpm: bpm)
        )
    }

    private func stageLinqHasNoLayer(_ layer: Int) -> Bool {
        guard testLink?.roster.denonOn == true else { return false }
        guard let sl = stageLinq else { return true }
        return !sl.devices.contains { device in
            device.decks.contains { $0.id - 1 == layer && ($0.songLoaded || !(TrackNaming.cleanTitle($0.trackTitle).isEmpty)) }
        }
    }

    // MARK: Snapshot de deck específico

    private func snapshotForDeckID(_ id: String) -> SyncSnapshot? {
        if id == DeckDisplayBuilder.testPioneerID || Self.sameDeckID(id, DeckDisplayBuilder.testPioneerID) {
            guard let overlay = pioneerTestOverlay() else { return nil }
            return makeTestLinkSyncSnapshot(overlay, label: "CDJ-3000 TEST",
                                            id: DeckDisplayBuilder.testPioneerID,
                                            isMaster: overlay.isMaster || overlay.playing)
        }
        if id.hasPrefix("denon-test-"),
           let layer = Int(id.dropFirst("denon-test-".count)) {
            if let overlay = denonTestOverlay(layer: layer) {
                let name = layer == 0 ? "A" : "B"
                return makeTestLinkSyncSnapshot(overlay, label: "Denon TEST \(name)",
                                                id: DeckDisplayBuilder.testDenonID(layer),
                                                isMaster: overlay.isMaster)
            }
        }
        if id.hasPrefix("denon-"), !id.hasPrefix("denon-test-"), let sl = stageLinq {
            let denonOn = testLink?.roster.denonOn == true
            for device in sl.devices {
                for deck in device.decks {
                    if "denon-\(device.id)-\(deck.id)" == id {
                        let overlay = denonOn ? testLink?.snapshot?.deck(deck.id - 1) : nil
                        return makeDenonSnapshot(deck: deck, device: device, overlay: overlay)
                    }
                }
            }
            if let layer = Self.denonLayer(id), let overlay = denonTestOverlay(layer: layer) {
                let name = layer == 0 ? "A" : "B"
                return makeTestLinkSyncSnapshot(overlay, label: "Denon TEST \(name)",
                                                id: DeckDisplayBuilder.testDenonID(layer),
                                                isMaster: overlay.isMaster)
            }
        }
        if id.hasPrefix("pioneer-"), let pdl = proDJLink {
            for device in pdl.devices {
                if "pioneer-\(device.id)" == id {
                    return makePioneerSnapshot(device: device, overlay: nil)
                }
            }
        }
        return nil
    }

    private func makeTestLinkSyncSnapshot(_ overlay: TestLinkDeck, label: String,
                                          id: String, isMaster: Bool) -> SyncSnapshot {
        let bpm = MusicalClock.bpm(overlay.bpm)
        let title = TrackNaming.cleanTitle(overlay.title)
        return SyncSnapshot(
            bpm: bpm,
            beatInBar: MusicalClock.beatInBar(position: overlay.position, bpm: bpm),
            beatCount: MusicalClock.beatCount(position: overlay.position, bpm: bpm),
            playhead: overlay.position,
            isPlaying: overlay.playing,
            sourceLabel: label,
            trackTitle: title.isEmpty ? nil : title,
            trackArtist: overlay.artist.isEmpty ? nil : overlay.artist,
            sourceDeckID: id,
            isMaster: isMaster,
            isOnAir: false
        )
    }

    private func makeDenonSnapshot(deck: DeckState, device: StageLinqDevice, overlay: TestLinkDeck?) -> SyncSnapshot {
        let b = Int(deck.currentBeat)
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0, deck.bpm, deck.beatBpm)
        let playhead: Double? = {
            if let o = overlay { return o.position }
            return deck.beatProgress.map { $0 * deck.trackLength }
        }()
        let playing = overlay?.playing ?? (deck.playState == .playing)
        let title = TrackNaming.cleanTitle(overlay?.title ?? deck.trackTitle)
        let id = overlay != nil
            ? DeckDisplayBuilder.testDenonID(deck.id - 1)
            : "denon-\(device.id)-\(deck.id)"
        return SyncSnapshot(
            bpm: bpm,
            beatInBar: overlay != nil
                ? MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm)
                : (b > 0 ? (b % 4) + 1 : 0),
            beatCount: overlay != nil
                ? MusicalClock.beatCount(position: overlay?.position ?? 0, bpm: bpm)
                : b,
            playhead: playhead,
            isPlaying: playing,
            sourceLabel: "Denon deck \(deck.id)",
            trackTitle: title.isEmpty ? nil : title,
            trackArtist: (overlay?.artist ?? deck.trackArtist).isEmpty ? nil : (overlay?.artist ?? deck.trackArtist),
            sourceDeckID: id,
            isMaster: overlay?.isMaster ?? deck.isMaster,
            isOnAir: false
        )
    }

    private func makePioneerSnapshot(device: ProDJLinkDevice, overlay: TestLinkDeck?) -> SyncSnapshot {
        let bpm = MusicalClock.bpm(overlay?.bpm ?? 0, device.effectiveBPM, device.trackBPM)
        let playhead: Double? = {
            if let o = overlay { return o.position }
            return device.hasPosition ? device.playhead : nil
        }()
        // Título: overlay TestLink tiene prioridad; si no, metadatos DBSERVER del CDJ
        let overlayTitle = overlay?.title ?? ""
        let rawTitle = overlayTitle.isEmpty ? device.trackTitle : overlayTitle
        let title = TrackNaming.cleanTitle(rawTitle)
        let artist: String? = (overlay?.artist).flatMap { $0.isEmpty ? nil : $0 }
                           ?? (device.trackArtist.isEmpty ? nil : device.trackArtist)
        let trackKey: String? = device.trackKey.isEmpty ? nil : device.trackKey
        return SyncSnapshot(
            bpm: bpm,
            beatInBar: overlay != nil
                ? MusicalClock.beatInBar(position: overlay?.position ?? 0, bpm: bpm)
                : device.beatInBar,
            beatCount: overlay != nil
                ? MusicalClock.beatCount(position: overlay?.position ?? 0, bpm: bpm)
                : device.beatCount,
            playhead: playhead,
            isPlaying: overlay?.playing ?? device.isPlaying,
            sourceLabel: "CDJ player \(device.playerNumber)",
            trackTitle: title.isEmpty ? nil : title,
            trackArtist: artist,
            trackKey: trackKey,
            sourceDeckID: "pioneer-\(device.id)",
            isMaster: overlay != nil ? (overlay?.isMaster ?? false) : device.isMaster,
            isOnAir: overlay != nil ? false : device.isOnAir
        )
    }

    // MARK: Master snapshot (fader / On Air / Master LED / el que suena)

    private func snapshotForMaster() -> SyncSnapshot {
        if !ltcAutoFollow, let id = ltcSourceDeckID {
            if let specific = snapshotForDeckID(id) { return specific }
            if let layer = Self.denonLayer(id),
               let overlay = denonTestOverlay(layer: layer) {
                let name = layer == 0 ? "A" : "B"
                return makeTestLinkSyncSnapshot(overlay, label: "Denon TEST \(name)",
                                                id: DeckDisplayBuilder.testDenonID(layer),
                                                isMaster: overlay.isMaster)
            }
        }
        return currentSnapshot()
    }

    private func currentSnapshot() -> SyncSnapshot {
        var masterPlaying: SyncSnapshot?
        var onAirPlaying: SyncSnapshot?
        var anyPlaying: SyncSnapshot?
        var anyMaster: SyncSnapshot?
        var anyLoaded: SyncSnapshot?

        func consider(_ snap: SyncSnapshot) {
            if snap.playhead != nil && anyLoaded == nil { anyLoaded = snap }
            if snap.isPlaying && anyPlaying == nil { anyPlaying = snap }
            if snap.isOnAir && snap.isPlaying && onAirPlaying == nil { onAirPlaying = snap }
            if snap.isMaster {
                if anyMaster == nil { anyMaster = snap }
                if snap.isPlaying && masterPlaying == nil { masterPlaying = snap }
            }
        }

        if let sl = stageLinq {
            let denonOn = testLink?.roster.denonOn == true
            for device in sl.devices {
                for deck in device.decks where deck.songLoaded && !deck.trackTitle.isEmpty {
                    let overlay = denonOn ? testLink?.snapshot?.deck(deck.id - 1) : nil
                    consider(makeDenonSnapshot(deck: deck, device: device, overlay: overlay))
                }
            }
        }

        if let overlay = denonTestOverlay(layer: 0) {
            consider(makeTestLinkSyncSnapshot(overlay, label: "Denon TEST A",
                                              id: DeckDisplayBuilder.testDenonID(0),
                                              isMaster: overlay.isMaster))
        }
        if let overlay = denonTestOverlay(layer: 1) {
            consider(makeTestLinkSyncSnapshot(overlay, label: "Denon TEST B",
                                              id: DeckDisplayBuilder.testDenonID(1),
                                              isMaster: overlay.isMaster))
        }

        if let pdl = proDJLink {
            for device in pdl.devices {
                if !shouldUsePioneer(device) { continue }
                consider(makePioneerSnapshot(device: device, overlay: nil))
            }
        }

        if let overlay = pioneerTestOverlay() {
            consider(makeTestLinkSyncSnapshot(overlay, label: "CDJ-3000 TEST",
                                              id: DeckDisplayBuilder.testPioneerID,
                                              isMaster: overlay.isMaster || overlay.playing))
        }

        return masterPlaying ?? onAirPlaying ?? anyPlaying ?? anyMaster ?? anyLoaded ?? SyncSnapshot.idle
    }

    private func pioneerTestOverlay() -> TestLinkDeck? {
        guard testLink?.roster.hasPioneerTrack == true else { return nil }
        if let snap = testLink?.snapshot {
            if let playing = snap.decks.first(where: { $0.loaded && $0.playing }) { return playing }
            return snap.firstLoadedDeck()
        }
        return nil
    }

    private func denonTestOverlay(layer: Int) -> TestLinkDeck? {
        guard testLink?.roster.denonOn == true else { return nil }
        return testLink?.snapshot?.deck(layer)
    }

    /// IDs estables: `denon-test-0` es la misma capa que `denon-<uuid>-1`.
    static func sameDeckID(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aTest = a.hasPrefix("denon-test-")
        let bTest = b.hasPrefix("denon-test-")
        if aTest || bTest, let la = denonLayer(a), let lb = denonLayer(b) {
            return la == lb
        }
        return false
    }

    private static func denonLayer(_ id: String) -> Int? {
        if id.hasPrefix("denon-test-") {
            return Int(id.dropFirst("denon-test-".count))
        }
        if id.hasPrefix("denon-") {
            if let last = id.split(separator: "-").last, let deckID = Int(last) {
                return deckID - 1
            }
        }
        return nil
    }

    /// El simulador Pioneer local no pinta salidas: la fila `pioneer-test` ya
    /// lleva título/BPM/playhead por TestLink.
    private func shouldUsePioneer(_ device: ProDJLinkDevice) -> Bool {
        if device.isOwnVirtualCDJ { return false }
        if device.looksLikeLegacyFakeClock { return false }
        if device.isLocalTestSimulator { return false }
        return device.trackLoaded
    }
}
