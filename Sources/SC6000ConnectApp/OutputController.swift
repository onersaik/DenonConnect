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
#if os(macOS)
import AppKit
#endif
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
    /// Varias salidas: el mismo bitstream Master se duplica en cada device.
    @Published var ltcSelectedDeviceIDs: [AudioDeviceID] = [0]
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
    @Published var ltcDeckDeviceIDs: [String: [AudioDeviceID]] = [:]
    @Published var ltcDeckTimecode: [String: String] = [:]
    @Published var ltcDeckError: [String: String] = [:]
    @Published var ltcDeckFrameRates: [String: LTCGenerator.FrameRate] = [:]
    @Published var ltcDeviceWarning: String = ""
    /// LOCK por fila: el Master auto-follow / fader / On Air no pisan este deck.
    /// Con LTC propio en otra salida, su generador sigue el playhead de esta fila.
    @Published var ltcDeckLocked: [String: Bool] = [:]

    // MARK: MIDI Timecode (MTC)
    @Published var mtcEnabled         = false
    @Published var mtcFrameRate: MIDITimecodeGenerator.FrameRate = .fps25
    @Published var mtcError: String   = ""

    // MARK: Servidor Web / OBS
    @Published var webEnabled         = false
    @Published var webPort: String    = "8080"
    @Published var webError: String   = ""
    @Published var obsTransparent     = true
    @Published var copiedHint         = ""

    // MARK: Reloj
    @Published var clockSource        = "—"
    @Published var clockBPM: Double   = 0

    // MARK: Historial
    @Published var playlistHistory: [PlaylistEntry] = []
    @Published var historyAutoSave: Bool = UserDefaults.standard.object(forKey: "sc.historyAutoSave") as? Bool ?? true {
        didSet { UserDefaults.standard.set(historyAutoSave, forKey: "sc.historyAutoSave") }
    }
    @Published var historyFolderPath: String = UserDefaults.standard.string(forKey: "sc.historyFolderPath") ?? "" {
        didSet { UserDefaults.standard.set(historyFolderPath, forKey: "sc.historyFolderPath") }
    }
    private var lastTrackedByDeck: [String: String] = [:]

    var historyFolderURL: URL {
        if !historyFolderPath.isEmpty {
            return URL(fileURLWithPath: historyFolderPath, isDirectory: true)
        }
        return Self.defaultHistoryFolder()
    }

    static func defaultHistoryFolder() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("STAGE CONNECT/historial", isDirectory: true)
    }

    // MARK: Privado
    private var bridge:  ResolumeBridge?
    private var ltc:     LTCFanout?
    private var deckLTC: [String: LTCFanout] = [:]
    private var mtc:     MIDITimecodeGenerator?
    private var web:     WebServer?
    private var timer:   Timer?

    private weak var stageLinq:  StageLinqManager?
    private weak var proDJLink:  ProDJLinkManager?
    private weak var testLink:   TestLinkReceiver?
    private weak var software:   SoftwareDJManager?
    private weak var tracklist:  TracklistStore?
    private var logSink: ((String) -> Void)?

    var ltcAnyEnabled: Bool { ltcEnabled || deckLTC.contains { $0.value.isRunning } }

    // MARK: Inicio

    func attach(stageLinq: StageLinqManager, proDJLink: ProDJLinkManager, testLink: TestLinkReceiver? = nil,
                software: SoftwareDJManager? = nil, tracklist: TracklistStore? = nil) {
        self.stageLinq = stageLinq
        self.proDJLink = proDJLink
        self.testLink  = testLink
        self.software  = software
        self.tracklist = tracklist
        self.logSink   = { [weak stageLinq] msg in stageLinq?.log(msg) }
        ltcDevices     = LTCGenerator.availableOutputDevices()
        loadHistoryFromDisk()

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

    func isDeckLocked(_ id: String) -> Bool {
        for (key, on) in ltcDeckLocked where on {
            if Self.sameDeckID(key, id) { return true }
        }
        return false
    }

    func toggleDeckLock(_ id: String) {
        setDeckLocked(id, locked: !isDeckLocked(id))
    }

    func setDeckLocked(_ id: String, locked: Bool) {
        ltcDeckLocked[canonicalDeckKey(id)] = locked
    }

    /// El deck emite LTC en un dispositivo distinto al Master de casa.
    func hasSeparateLTCOutput(_ id: String) -> Bool {
        guard isDeckLTCEnabled(id) else { return false }
        if !ltcEnabled { return true }
        let deckSet = Set(deckDeviceIDs(id).map { resolvedDeviceID($0) })
        let masterSet = Set(masterDeviceIDs.map { resolvedDeviceID($0) })
        return !deckSet.isSubset(of: masterSet) || deckSet.count != masterSet.count
    }

    var masterDeviceIDs: [AudioDeviceID] {
        LTCFanout.uniqueIDs(ltcSelectedDeviceIDs)
    }

    func deckDeviceIDs(_ id: String) -> [AudioDeviceID] {
        LTCFanout.uniqueIDs(ltcDeckDeviceIDs[generatorKey(for: id)] ?? [0])
    }

    func isMasterDeviceSelected(_ deviceID: AudioDeviceID) -> Bool {
        masterDeviceIDs.contains(deviceID)
    }

    func isDeckDeviceSelected(_ id: String, deviceID: AudioDeviceID) -> Bool {
        deckDeviceIDs(id).contains(deviceID)
    }

    /// Quién más (otra fuente LTC) usa ya este device. Vacío = libre o es la misma fuente.
    func conflictOwners(for deviceID: AudioDeviceID, excluding slot: String) -> [String] {
        let want = resolvedDeviceID(deviceID)
        var owners: [String] = []
        if slot != "master" {
            for id in masterDeviceIDs where resolvedDeviceID(id) == want && ltcEnabled {
                owners.append("MASTER")
            }
        }
        for (key, fan) in deckLTC where fan.isRunning {
            if Self.sameDeckID(key, slot) { continue }
            for id in deckDeviceIDs(key) where resolvedDeviceID(id) == want {
                let label = ltcDeckSlots.first { Self.sameDeckID($0.id, key) }?.label ?? key
                owners.append(label)
            }
        }
        return owners
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

    /// Fila que MST está mostrando / anclando. Independiente de SMPTE.
    func isMasterFocus(_ id: String) -> Bool {
        if !ltcAutoFollow, let pinned = ltcSourceDeckID {
            return Self.sameDeckID(pinned, id)
        }
        if let hot = hotDeckID {
            return Self.sameDeckID(hot, id)
        }
        return false
    }

    /// Ancla esta fila como MASTER de monitor (la que “está saliendo”).
    /// No enciende SMPTE: eso es el botón SMPTE / el MASTER de la cabecera.
    func pinMaster(to id: String) {
        if !ltcAutoFollow, let current = ltcSourceDeckID, Self.sameDeckID(current, id) {
            setAutoFollow(true)
            return
        }
        ltcSourceDeckID = id
        ltcAutoFollow = false
        if ltcEnabled, !isDeckLocked(id) {
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
        let ids = masterDeviceIDs
        refreshDeviceWarning()
        let snap = snapshotForMaster()
        do {
            let fan = LTCFanout(name: "Master", log: { [weak self] in self?.logSink?($0) })
            fan.frameRate = ltcFrameRate
            try fan.start(deviceIDs: ids, playhead: snap.playhead, playing: false)
            applyPlayhead(fan, snap)
            ltc = fan
            ltcEnabled = true
            ltcFollowedDeckID = snap.sourceDeckID
            ltcTimecode = Self.timecode(snap, fps: ltcFrameRate)
            refreshDeviceWarning()
            logSink?("[SMPTE] Master ON — \(ids.count) salida\(ids.count == 1 ? "" : "s") — \(snap.sourceLabel)")
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
        let ids = deckDeviceIDs(key)
        refreshDeviceWarning()
        let snap = snapshotForDeckID(key) ?? snapshotForDeckID(id)
        do {
            let label = ltcDeckSlots.first { Self.sameDeckID($0.id, key) }?.label ?? key
            let deckRate = ltcDeckFrameRates[key] ?? ltcFrameRate
            let fan = LTCFanout(name: label, log: { [weak self] in self?.logSink?($0) })
            fan.frameRate = deckRate
            try fan.start(deviceIDs: ids, playhead: snap?.playhead, playing: false)
            applyPlayhead(fan, snap)
            deckLTC[key] = fan
            ltcDeckEnabled[key] = true
            ltcDeckTimecode[key] = Self.timecode(snap, fps: deckRate)
            refreshDeviceWarning()
            logSink?("[SMPTE] Deck ON \(label) — \(ids.count) salida\(ids.count == 1 ? "" : "s")")
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
        toggleDeckDevice(id, deviceID: deviceID, on: true)
    }

    func toggleMasterDevice(_ deviceID: AudioDeviceID) {
        var ids = ltcSelectedDeviceIDs
        if ids.contains(deviceID) {
            ids.removeAll { $0 == deviceID }
        } else {
            ids.append(deviceID)
        }
        ltcSelectedDeviceIDs = LTCFanout.uniqueIDs(ids)
        if ltcEnabled { startMasterLTC() } else { refreshDeviceWarning() }
    }

    func toggleDeckDevice(_ id: String, deviceID: AudioDeviceID, on: Bool? = nil) {
        let key = generatorKey(for: id)
        var ids = ltcDeckDeviceIDs[key] ?? [0]
        let shouldOn = on ?? !ids.contains(deviceID)
        if shouldOn {
            if !ids.contains(deviceID) { ids.append(deviceID) }
        } else {
            ids.removeAll { $0 == deviceID }
        }
        ltcDeckDeviceIDs[key] = LTCFanout.uniqueIDs(ids)
        if isDeckLTCEnabled(key) {
            startDeckLTC(key)
        } else {
            refreshDeviceWarning()
        }
    }

    func setDeckFrameRate(_ id: String, rate: LTCGenerator.FrameRate) {
        let key = generatorKey(for: id)
        ltcDeckFrameRates[key] = rate
        if isDeckLTCEnabled(key) {
            startDeckLTC(key)  // restart with new rate
        }
    }

    func deckDeviceBinding(_ id: String) -> AudioDeviceID {
        deckDeviceIDs(id).first ?? 0
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
            srv.failureHandler = { [weak self] msg in
                DispatchQueue.main.async {
                    self?.web?.stop()
                    self?.web = nil
                    self?.webEnabled = false
                    self?.webError = msg
                }
            }
            do {
                try srv.start()
                web = srv; webEnabled = true; webError = ""
            } catch {
                webError = Self.webErrorText(error, port: port)
                logSink?("[Web] Error al iniciar: \(webError)")
            }
        }
    }

    var webPortNumber: UInt16 { UInt16(webPort) ?? 8080 }

    var webLocalURL: String { "http://127.0.0.1:\(webPortNumber)" }

    var webLANURL: String {
        "http://\(NetworkInfo.describe(NetworkInfo.localIPv4Bytes())):\(webPortNumber)"
    }

    func obsURL(lan: Bool, transparent: Bool? = nil) -> String {
        let base = lan ? webLANURL : webLocalURL
        let t = transparent ?? obsTransparent
        return t ? "\(base)/obs?t=1" : "\(base)/obs"
    }

    func copyToPasteboard(_ text: String, hint: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copiedHint = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.copiedHint == hint { self?.copiedHint = "" }
        }
        #endif
    }

    func copyTimecode() {
        copyToPasteboard(ltcTimecode, hint: "TC copiado")
    }

    private static func webErrorText(_ error: Error, port: UInt16) -> String {
        let raw = (error as NSError)
        if raw.domain == NSPOSIXErrorDomain, raw.code == EADDRINUSE {
            return "Puerto \(port) ocupado. Cambia el puerto o cierra la otra app que lo usa."
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("address already") || desc.contains("in use") || desc.contains("48") {
            return "Puerto \(port) ocupado. Cambia el puerto o cierra la otra app que lo usa."
        }
        return "No se pudo abrir el puerto \(port): \(error.localizedDescription)"
    }

    // MARK: Historial

    func clearHistory() {
        playlistHistory.removeAll()
        lastTrackedByDeck.removeAll()
        persistHistory()
    }

    func persistHistory() {
        guard historyAutoSave else { return }
        let folder = historyFolderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            logSink?("[Historial] No se pudo crear \(folder.path): \(error.localizedDescription)")
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let jsonURL = folder.appendingPathComponent("historial.json")
        if let data = try? enc.encode(playlistHistory) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        let lines = playlistHistory.reversed().map { entry in
            "\(entry.formattedTime)\t\(entry.artist)\t\(entry.title)\t\(entry.source)"
        }
        let txt = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? txt.write(to: folder.appendingPathComponent("historial.txt"), atomically: true, encoding: .utf8)
    }

    func loadHistoryFromDisk() {
        let url = historyFolderURL.appendingPathComponent("historial.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let entries = try? dec.decode([PlaylistEntry].self, from: data) {
            playlistHistory = entries
        }
    }

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
        if hotDeckID != masterSnapshot.sourceDeckID {
            hotDeckID = masterSnapshot.sourceDeckID
        }

        bridge?.send(masterSnapshot)

        if ltcEnabled {
            let snap = snapshotForMaster()
            if clockSource != snap.sourceLabel { clockSource = snap.sourceLabel }
            if abs(clockBPM - snap.bpm) > 0.01 { clockBPM = snap.bpm }
            applyToMaster(snap)
            if ltcFollowedDeckID != snap.sourceDeckID {
                ltcFollowedDeckID = snap.sourceDeckID
            }
            let tc = Self.timecode(snap, fps: ltcFrameRate)
            if ltcTimecode != tc { ltcTimecode = tc }
        } else {
            if ltcFollowedDeckID != nil { ltcFollowedDeckID = nil }
            if clockSource != masterSnapshot.sourceLabel {
                clockSource = masterSnapshot.sourceLabel
            }
            if abs(clockBPM - masterSnapshot.bpm) > 0.01 {
                clockBPM = masterSnapshot.bpm
            }
        }

        for (key, gen) in deckLTC {
            guard gen.isRunning else { continue }
            let snap = snapshotForDeckID(key)
            applyPlayhead(gen, snap)
            let tc = Self.timecode(snap, fps: ltcDeckFrameRates[key] ?? ltcFrameRate)
            if ltcDeckTimecode[key] != tc {
                ltcDeckTimecode[key] = tc
            }
        }

        if mtcEnabled, let mtc {
            let snap = ltcEnabled ? snapshotForMaster() : masterSnapshot
            applyPlayhead(mtc: mtc, snap)
        }

        trackHistoryIfNeeded()
        ingestTracklist()
    }

    func liveDeckSnapshots() -> [DeckSnapshot] { currentDeckSnapshots() }

    private func ingestTracklist() {
        let playing = currentDeckSnapshots().compactMap { d -> (String, String, String, Bool)? in
            guard d.isPlaying, !d.title.isEmpty else { return nil }
            return (d.title, d.artist, d.label, d.isMaster || d.ltcSource)
        }
        let store = tracklist
        DispatchQueue.main.async {
            guard let store, !store.items.isEmpty else { return }
            store.ingest(playing: playing)
        }
    }

    // MARK: Generadores

    private func applyToMaster(_ snap: SyncSnapshot?) {
        applyPlayhead(ltc, snap)
    }

    private func applyPlayhead(_ fan: LTCFanout?, _ snap: SyncSnapshot?) {
        guard let fan else { return }
        guard let snap else {
            fan.setPaused(true)
            return
        }
        guard let playhead = snap.playhead, playhead.isFinite, playhead >= 0 else {
            fan.setPaused(true)
            return
        }
        fan.applyPlayhead(seconds: playhead, playing: snap.isPlaying)
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
        conflictOwners(for: deviceID, excluding: slot).first
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
        var clashes: [String] = []
        func note(_ deviceID: AudioDeviceID, label: String) {
            let rid = resolvedDeviceID(deviceID)
            if let prev = seen[rid], prev != label {
                clashes.append("\(prev) y \(label)")
            } else {
                seen[rid] = label
            }
        }
        if ltcEnabled {
            for id in masterDeviceIDs { note(id, label: "MASTER") }
        }
        for (key, fan) in deckLTC where fan.isRunning {
            let label = ltcDeckSlots.first { Self.sameDeckID($0.id, key) }?.label ?? key
            for id in deckDeviceIDs(key) { note(id, label: label) }
        }
        if clashes.isEmpty {
            ltcDeviceWarning = ""
        } else {
            let uniq = Array(Set(clashes)).sorted()
            ltcDeviceWarning = "\(uniq.joined(separator: "; ")): mismo canal, los timecodes se pisan. El mismo LTC en dos devices distintos es correcto."
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
            for device in sl.devices {
                for deck in device.decks {
                    let overlay = denonOverlay(for: device, deck: deck)
                    let loaded = overlay?.loaded ?? deck.songLoaded
                    guard loaded else { continue }
                    let layer = DeckDisplayBuilder.denonLayerCaption(deck.id)
                    let id = device.isDenonSimulator
                        ? DeckDisplayBuilder.testDenonID(deck.id - 1)
                        : "denon-\(device.id)-\(deck.id)"
                    add(id, device.isDenonSimulator
                        ? DeckDisplayBuilder.productDenonLabel(layer: deck.id)
                        : "SC6000 · \(DeckDisplayBuilder.displayDeviceName(device.name.isEmpty ? "SC6000" : device.name)) \(layer)")
                }
            }
        }
        if testLink?.roster.denonOn == true {
            if let layers = testLink?.roster.loadedLayers {
                for idx in layers.indices where testLink?.roster.layerLoaded(idx) == true {
                    add(
                        DeckDisplayBuilder.testDenonID(idx),
                        DeckDisplayBuilder.productDenonLabel(layer: idx + 1)
                    )
                }
            }
        }
        if testLink?.roster.hasPioneerTrack == true {
            add(DeckDisplayBuilder.testPioneerID, DeckDisplayBuilder.productPioneerLabel())
        }
        if let pdl = proDJLink {
            for device in pdl.devices {
                if !shouldUsePioneer(device) { continue }
                    add("pioneer-\(device.id)", DeckDisplayBuilder.productPioneerLabel(player: Int(device.playerNumber), model: device.model))
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

    private func trackHistoryIfNeeded() {
        for snap in currentDeckSnapshots() {
            guard snap.isPlaying, !snap.title.isEmpty else { continue }
            let trackKey = snap.title + "|" + snap.artist
            if lastTrackedByDeck[snap.label] == trackKey { continue }
            lastTrackedByDeck[snap.label] = trackKey
            let entry = PlaylistEntry(
                id: UUID(),
                timestamp: Date(),
                title: snap.title,
                artist: snap.artist,
                source: snap.label
            )
            playlistHistory.insert(entry, at: 0)
            persistHistory()
        }
    }

    // MARK: DeckSnapshots para el servidor web

    private func currentDeckSnapshots() -> [DeckSnapshot] {
        var result: [DeckSnapshot] = []
        if let sl = stageLinq {
            for device in sl.devices {
                for deck in device.decks {
                    let overlay = denonOverlay(for: device, deck: deck)
                    guard overlay?.loaded ?? deck.songLoaded else { continue }
                    let bpm = MusicalClock.bpm(overlay?.bpm ?? 0, deck.bpm, deck.beatBpm)
                    let layer = DeckDisplayBuilder.denonLayerCaption(deck.id)
                    let denonLabel = device.isDenonSimulator
                        ? DeckDisplayBuilder.productDenonLabel(layer: deck.id)
                        : "SC6000 · \(DeckDisplayBuilder.displayDeviceName(device.name.isEmpty ? "SC6000" : device.name)) \(layer)"
                    let prog  = overlay?.progress ?? deck.beatProgress
                    let elapsed: Double? = overlay?.position ?? prog.map { $0 * deck.trackLength }
                    let deckID = device.isDenonSimulator
                        ? DeckDisplayBuilder.testDenonID(deck.id - 1)
                        : "denon-\(device.id)-\(deck.id)"
                    let isLTCSrc = hotDeckID == deckID
                    let dTag = Self.storedTag(
                        device.isDenonSimulator
                            ? DeckLabelKey.denonTest(deck.id - 1)
                            : DeckLabelKey.denon(token: device.token, layer: deck.id),
                        fallback: layer
                    )
                    result.append(DeckSnapshot(
                        label:     denonLabel,
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
                            : Int(deck.currentBeat.truncatingRemainder(dividingBy: 4)) + 1,
                        key:       deck.trackKey,
                        ltcSource: isLTCSrc,
                        tcTimecode: ltcDeckTimecode[deckID] ?? (isLTCSrc && ltcEnabled ? ltcTimecode : nil),
                        tag:       dTag
                    ))
                }
            }
        }
        if let overlay = pioneerTestOverlay() {
            let snap = makeTestLinkSyncSnapshot(overlay, label: DeckDisplayBuilder.productPioneerLabel(),
                                                id: DeckDisplayBuilder.testPioneerID,
                                                isMaster: overlay.playing)
            result.append(DeckSnapshot(
                label:     DeckDisplayBuilder.productPioneerLabel(),
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
        if let layers = testLink?.roster.loadedLayers {
            for idx in layers.indices {
                guard let overlay = denonTestOverlay(layer: idx), stageLinqHasNoLayer(idx) else { continue }
                let master = idx == 0 ? (overlay.isMaster || overlay.playing) : overlay.isMaster
                result.append(testDeckSnapshot(overlay, label: DeckDisplayBuilder.productDenonLabel(layer: idx + 1), master: master))
            }
        }
        if let pdl = proDJLink {
            for device in pdl.devices {
                if !shouldUsePioneer(device) { continue }
                let bpm = MusicalClock.bpm(device.effectiveBPM, device.trackBPM)
                let pID = "pioneer-\(device.id)"
                let pIsLTCSrc = hotDeckID == pID
                let pTag = Self.storedTag(
                    DeckLabelKey.pioneer(ip: device.ip, player: device.playerNumber),
                    fallback: "\(device.playerNumber)"
                )
                result.append(DeckSnapshot(
                    label:     DeckDisplayBuilder.productPioneerLabel(player: Int(device.playerNumber), model: device.model),
                    title:     device.trackTitle,
                    artist:    device.trackArtist,
                    bpm:       bpm,
                    isPlaying: device.isPlaying,
                    isMaster:  device.isMaster,
                    elapsed:   device.resolvedPlayhead,
                    duration:  device.trackLength > 0 ? device.trackLength : nil,
                    progress:  device.trackLength > 0 && device.resolvedPlayhead != nil ? device.progress : nil,
                    beatInBar: device.beatInBar,
                    key:       device.trackKey,
                    pitchPct:  device.pitchPercent,
                    isOnAir:   device.isOnAir,
                    ltcSource: pIsLTCSrc,
                    tcTimecode: ltcDeckTimecode[pID] ?? (pIsLTCSrc && ltcEnabled ? ltcTimecode : nil),
                    tag:       pTag
                ))
            }
        }
        if let soft = software {
            for deck in soft.liveDecks {
                result.append(DeckSnapshot(
                    label:     deck.shortName,
                    title:     TrackNaming.cleanTitle(deck.title),
                    artist:    deck.artist,
                    bpm:       deck.bpm,
                    isPlaying: deck.playing,
                    isMaster:  false,
                    elapsed:   deck.position,
                    duration:  nil,
                    progress:  nil,
                    beatInBar: MusicalClock.beatInBar(position: deck.position, bpm: deck.bpm),
                    tag:       Self.storedTag(deck.id, fallback: "\(deck.deckIndex + 1)")
                ))
            }
        }
        return result
    }

    private static func storedTag(_ key: String, fallback: String) -> String {
        let raw = UserDefaults.standard.dictionary(forKey: "sc.deckLabels.v1") as? [String: String]
        if let t = raw?[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return fallback
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
            return makeTestLinkSyncSnapshot(overlay, label: DeckDisplayBuilder.productPioneerLabel(),
                                            id: DeckDisplayBuilder.testPioneerID,
                                            isMaster: overlay.isMaster || overlay.playing)
        }
        if id.hasPrefix("denon-test-"),
           let layer = Int(id.dropFirst("denon-test-".count)) {
            if let overlay = denonTestOverlay(layer: layer) {
                return makeTestLinkSyncSnapshot(overlay, label: DeckDisplayBuilder.productDenonLabel(layer: layer + 1),
                                                id: DeckDisplayBuilder.testDenonID(layer),
                                                isMaster: overlay.isMaster)
            }
        }
        if id.hasPrefix("denon-"), !id.hasPrefix("denon-test-"), let sl = stageLinq {
            for device in sl.devices {
                for deck in device.decks {
                    if "denon-\(device.id)-\(deck.id)" == id {
                        return makeDenonSnapshot(deck: deck, device: device, overlay: denonOverlay(for: device, deck: deck))
                    }
                }
            }
            if let layer = Self.denonLayer(id), let overlay = denonTestOverlay(layer: layer) {
                return makeTestLinkSyncSnapshot(overlay, label: DeckDisplayBuilder.productDenonLabel(layer: layer + 1),
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
            if deck.trackLength > 0, let p = deck.beatProgress { return p * deck.trackLength }
            if deck.currentBeat > 0, bpm > 0 { return deck.currentBeat * 60.0 / bpm }
            return nil
        }()
        let playing = overlay?.playing ?? (deck.playState == .playing)
        let title = TrackNaming.cleanTitle(overlay?.title ?? deck.trackTitle)
        let id = device.isDenonSimulator
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
            sourceLabel: device.isDenonSimulator
                ? DeckDisplayBuilder.productDenonLabel(layer: deck.id)
                : "SC6000 · \(DeckDisplayBuilder.displayDeviceName(device.name.isEmpty ? "SC6000" : device.name)) \(DeckDisplayBuilder.denonLayerCaption(deck.id))",
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
            return device.resolvedPlayhead
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
            sourceLabel: DeckDisplayBuilder.productPioneerLabel(player: Int(device.playerNumber), model: device.model),
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
        if !ltcAutoFollow, let id = ltcSourceDeckID, !isDeckLocked(id) {
            if let specific = snapshotForDeckID(id) { return specific }
            if let layer = Self.denonLayer(id),
               let overlay = denonTestOverlay(layer: layer) {
                return makeTestLinkSyncSnapshot(overlay, label: DeckDisplayBuilder.productDenonLabel(layer: layer + 1),
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
            if let sid = snap.sourceDeckID, isDeckLocked(sid) { return }
            if snap.playhead != nil && anyLoaded == nil { anyLoaded = snap }
            if snap.isPlaying && anyPlaying == nil { anyPlaying = snap }
            if snap.isOnAir && snap.isPlaying && onAirPlaying == nil { onAirPlaying = snap }
            if snap.isMaster {
                if anyMaster == nil { anyMaster = snap }
                if snap.isPlaying && masterPlaying == nil { masterPlaying = snap }
            }
        }

        if let sl = stageLinq {
            for device in sl.devices {
                for deck in device.decks {
                    let overlay = denonOverlay(for: device, deck: deck)
                    guard overlay?.loaded ?? deck.songLoaded else { continue }
                    consider(makeDenonSnapshot(deck: deck, device: device, overlay: overlay))
                }
            }
        }

        if let layers = testLink?.roster.loadedLayers {
            for idx in layers.indices {
                guard let overlay = denonTestOverlay(layer: idx) else { continue }
                consider(makeTestLinkSyncSnapshot(overlay, label: DeckDisplayBuilder.productDenonLabel(layer: idx + 1),
                                                  id: DeckDisplayBuilder.testDenonID(idx),
                                                  isMaster: overlay.isMaster))
            }
        }

        if let pdl = proDJLink {
            for device in pdl.devices {
                if !shouldUsePioneer(device) { continue }
                consider(makePioneerSnapshot(device: device, overlay: nil))
            }
        }

        if let overlay = pioneerTestOverlay() {
            consider(makeTestLinkSyncSnapshot(overlay, label: DeckDisplayBuilder.productPioneerLabel(),
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

    /// TEST overlay solo en el SIM. Un SC6000 de la LAN no hereda título/reloj TEST.
    private func denonOverlay(for device: StageLinqDevice, deck: DeckState) -> TestLinkDeck? {
        guard testLink?.roster.denonOn == true, device.isDenonSimulator else { return nil }
        return testLink?.snapshot?.deck(deck.id - 1)
    }

    /// `denon-test-0` ≡ SIM `denon-<localhost/SIM>-1`. Un SC6000 real no es esa capa:
    /// LOCK/MASTER del TEST no pueden pisar el hardware (Dual 8 filas).
    static func sameDeckID(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aTest = a.hasPrefix("denon-test-")
        let bTest = b.hasPrefix("denon-test-")
        guard aTest || bTest, let la = denonLayer(a), let lb = denonLayer(b), la == lb else {
            return false
        }
        if aTest && bTest { return true }
        return looksLikeDenonSimulatorID(aTest ? b : a)
    }

    private static func looksLikeDenonSimulatorID(_ id: String) -> Bool {
        if id.hasPrefix("denon-test-") { return true }
        let u = id.uppercased()
        if StageLinqDevice.isDenonSimulatorName(id) { return true }
        if u.contains("SC6000-SIM") || u.contains("SC6000 TEST") { return true }
        guard id.hasPrefix("denon-"), !id.hasPrefix("denon-test-") else { return false }
        let rest = String(id.dropFirst("denon-".count))
        guard let dash = rest.lastIndex(of: "-") else { return false }
        let hostPort = String(rest[..<dash])
        let ip = hostPort.split(separator: ":").first.map(String.init) ?? hostPort
        return NetworkInfo.isLocalIPv4(ip)
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
        device.isLANPlayerWithTrack
    }
}
