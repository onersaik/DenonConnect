// MappingController.swift
// Atajos de teclado y MIDI learn para las acciones de cabecera / CONFIG.
// Note on o CC>64 = toggle o on; CC 0 = off cuando aplica.
// No interfiere con campos de texto. Persistencia en UserDefaults.

import AppKit
import Combine
import CoreMIDI
import Foundation
import SwiftUI

// MARK: - Acciones

enum MappingAction: String, CaseIterable, Identifiable, Codable {
    case toggleMasterSMPTE
    case toggleLTCFollow
    case modeAuto
    case modeDenon
    case modePioneer
    case modeTodos
    case layoutLarge
    case layoutSmall
    case layoutMaster
    case zoomIn
    case zoomOut
    case toggleConfig
    case toggleLog
    case toggleRow1SMPTE
    case toggleRow2SMPTE
    case toggleRow3SMPTE
    case toggleRow4SMPTE
    case toggleFocusedSMPTE
    case toggleRow1Lock
    case toggleRow2Lock
    case toggleRow3Lock
    case toggleRow4Lock
    case toggleFocusedLock
    case toggleResolume
    case toggleWebMonitor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleMasterSMPTE:   return "MASTER general"
        case .toggleLTCFollow:     return "MASTER auto (fader)"
        case .modeAuto:            return "Modo Auto"
        case .modeDenon:           return "Modo Denon"
        case .modePioneer:         return "Modo Pioneer"
        case .modeTodos:           return "Modo Todos"
        case .layoutLarge:         return "Vista CDJ"
        case .layoutSmall:         return "Vista Overview"
        case .layoutMaster:        return "Vista Master"
        case .zoomIn:              return "Zoom pista +"
        case .zoomOut:             return "Zoom pista -"
        case .toggleConfig:        return "CONFIG abrir/cerrar"
        case .toggleLog:           return "Log on/off"
        case .toggleRow1SMPTE:     return "SMPTE primera fila (F1)"
        case .toggleRow2SMPTE:     return "SMPTE 2ª fila (F2)"
        case .toggleRow3SMPTE:     return "SMPTE 3ª fila (F3)"
        case .toggleRow4SMPTE:     return "SMPTE 4ª fila (F4)"
        case .toggleFocusedSMPTE:  return "SMPTE fila enfocada"
        case .toggleRow1Lock:      return "LOCK primera fila"
        case .toggleRow2Lock:      return "LOCK 2ª fila"
        case .toggleRow3Lock:      return "LOCK 3ª fila"
        case .toggleRow4Lock:      return "LOCK 4ª fila"
        case .toggleFocusedLock:   return "LOCK fila enfocada"
        case .toggleResolume:      return "Resolume OSC on/off"
        case .toggleWebMonitor:    return "Web monitor on/off"
        }
    }

    var group: String {
        switch self {
        case .toggleMasterSMPTE, .toggleLTCFollow:
            return "Master"
        case .modeAuto, .modeDenon, .modePioneer, .modeTodos,
             .layoutLarge, .layoutSmall, .layoutMaster, .zoomIn, .zoomOut,
             .toggleConfig, .toggleLog:
            return "Vistas"
        case .toggleRow1SMPTE, .toggleRow2SMPTE, .toggleRow3SMPTE,
             .toggleRow4SMPTE, .toggleFocusedSMPTE:
            return "SMPTE"
        case .toggleRow1Lock, .toggleRow2Lock, .toggleRow3Lock,
             .toggleRow4Lock, .toggleFocusedLock:
            return "LOCK"
        case .toggleResolume, .toggleWebMonitor:
            return "Salidas"
        }
    }

    /// Si true, CC 0 apaga; Note/CC>64 hace toggle (o enciende si ya estaba off).
    var supportsOff: Bool {
        switch self {
        case .modeAuto, .modeDenon, .modePioneer, .modeTodos,
             .layoutLarge, .layoutSmall, .layoutMaster, .zoomIn, .zoomOut:
            return false
        default:
            return true
        }
    }
}

enum MappingForce {
    case toggle
    case on
    case off
}

enum MappingLearn: Equatable {
    case midi(MappingAction)
    case key(MappingAction)
}

struct KeyBinding: Codable, Equatable {
    var character: String
    var keyCode: UInt16?

    var label: String {
        switch character {
        case "f1": return "F1"
        case "f2": return "F2"
        case "f3": return "F3"
        case "f4": return "F4"
        case "esc": return "Esc"
        case " ": return "Espacio"
        default: return character.uppercased()
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        if let code = keyCode, event.keyCode == code { return true }
        if let mapped = KeyBinding.functionKey(for: event.keyCode) {
            return mapped == character
        }
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return !ch.isEmpty && ch == character
    }

    static func from(event: NSEvent) -> KeyBinding? {
        if event.keyCode == 53 { return KeyBinding(character: "esc", keyCode: 53) }
        if let fn = functionKey(for: event.keyCode) {
            return KeyBinding(character: fn, keyCode: event.keyCode)
        }
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard !ch.isEmpty, ch != "\u{1b}" else { return nil }
        if ch.count == 1, let s = ch.unicodeScalars.first, s.value < 32 { return nil }
        return KeyBinding(character: ch, keyCode: event.keyCode)
    }

    static func functionKey(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 122: return "f1"
        case 120: return "f2"
        case 99:  return "f3"
        case 118: return "f4"
        default:  return nil
        }
    }
}

struct MIDIBinding: Codable, Equatable, Hashable {
    var kind: String
    var channel: UInt8
    var number: UInt8

    var label: String {
        let ch = "ch\(Int(channel) + 1)"
        if kind == "note" { return "Nota \(number) \(ch)" }
        return "CC \(number) \(ch)"
    }
}

struct MIDISourceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let uniqueID: Int32
}

// MARK: - Controller

final class MappingController: ObservableObject {

    @Published var mode: AppMode = {
        let raw = UserDefaults.standard.string(forKey: "sc.appMode") ?? "Auto"
        // Dual unificado en Auto.
        if raw == "Dual" { return .auto }
        return AppMode(rawValue: raw) ?? .auto
    }() {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "sc.appMode") }
    }
    @Published var layout: DeckLayout = .small
    @Published var showLog = false
    @Published var showOutputs = false

    // MARK: Fuentes (ticks CONFIG) — Auto/Todos las respetan
    @Published var sourceDenon: Bool = UserDefaults.standard.object(forKey: "sc.src.denon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sourceDenon, forKey: "sc.src.denon") }
    }
    @Published var sourcePioneer: Bool = UserDefaults.standard.object(forKey: "sc.src.pioneer") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sourcePioneer, forKey: "sc.src.pioneer") }
    }
    @Published var sourceSerato: Bool = UserDefaults.standard.object(forKey: "sc.src.serato") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sourceSerato, forKey: "sc.src.serato") }
    }
    @Published var sourceVDJ: Bool = UserDefaults.standard.object(forKey: "sc.src.vdj") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sourceVDJ, forKey: "sc.src.vdj") }
    }
    @Published var sourceRekordbox: Bool = UserDefaults.standard.object(forKey: "sc.src.rekordbox") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sourceRekordbox, forKey: "sc.src.rekordbox") }
    }
    @Published var sourceTraktor: Bool = UserDefaults.standard.object(forKey: "sc.src.traktor") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sourceTraktor, forKey: "sc.src.traktor") }
    }

    func setAllSources(_ on: Bool) {
        sourceDenon = on
        sourcePioneer = on
        sourceSerato = on
        sourceVDJ = on
        sourceRekordbox = on
        sourceTraktor = on
    }

    var allSourcesEnabled: Bool {
        sourceDenon && sourcePioneer && sourceSerato && sourceVDJ && sourceRekordbox && sourceTraktor
    }
    @Published var waveformWindowSeconds: Double = {
        let raw = UserDefaults.standard.object(forKey: "sc.waveform.windowSeconds") as? Double
        return WaveformZoom.clamp(raw ?? WaveformZoom.defaultSeconds)
    }() {
        didSet { UserDefaults.standard.set(waveformWindowSeconds, forKey: "sc.waveform.windowSeconds") }
    }
    @Published var monitorWaveformWindowSeconds: Double = {
        let raw = UserDefaults.standard.object(forKey: "sc.monitor.windowSeconds") as? Double
        return WaveformZoom.clamp(raw ?? WaveformZoom.defaultSeconds)
    }() {
        didSet { UserDefaults.standard.set(monitorWaveformWindowSeconds, forKey: "sc.monitor.windowSeconds") }
    }

    @Published var keyBindings: [MappingAction: KeyBinding] = MappingController.defaultKeyBindings
    @Published var midiBindings: [MappingAction: MIDIBinding] = [:]
    @Published var sources: [MIDISourceInfo] = []
    @Published var selectedSourceID: String = ""
    @Published var learning: MappingLearn?
    @Published var lastMIDILabel: String = ""
    @Published var midiStatus: String = ""
    /// IDs de las filas visibles ahora (ContentView). F1–F4 y LOCK usan estos ids, no el índice de CONFIG.
    @Published var visibleRowIDs: [String] = []

    @Published var keyboardEnabled: Bool = UserDefaults.standard.object(forKey: "sc.mapping.keyboardOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keyboardEnabled, forKey: "sc.mapping.keyboardOn") }
    }
    @Published var midiEnabled: Bool = UserDefaults.standard.object(forKey: "sc.mapping.midiOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(midiEnabled, forKey: "sc.mapping.midiOn") }
    }

    private weak var outputs: OutputController?
    private var keyMonitor: Any?
    private var learnTimeout: DispatchWorkItem?
    private var midiClient: MIDIClientRef = 0
    private var midiPort: MIDIPortRef = 0
    private var connectedSources: [MIDIEndpointRef] = []
    private var started = false

    private static let keysDefaultsKey = "sc.mapping.keys"
    private static let midiDefaultsKey = "sc.mapping.midi"
    private static let sourceDefaultsKey = "sc.mapping.midiSource"

    static let defaultKeyBindings: [MappingAction: KeyBinding] = [
        .modeAuto:           KeyBinding(character: "1", keyCode: 18),
        .modeDenon:          KeyBinding(character: "2", keyCode: 19),
        .modePioneer:        KeyBinding(character: "3", keyCode: 20),
        .modeTodos:          KeyBinding(character: "4", keyCode: 21),
        .layoutLarge:        KeyBinding(character: "g", keyCode: 5),
        .layoutSmall:        KeyBinding(character: "p", keyCode: 35),
        .layoutMaster:       KeyBinding(character: "v", keyCode: 9),
        .zoomIn:             KeyBinding(character: "=", keyCode: 24),
        .zoomOut:            KeyBinding(character: "-", keyCode: 27),
        .toggleConfig:       KeyBinding(character: "c", keyCode: 8),
        .toggleLog:          KeyBinding(character: "l", keyCode: 37),
        .toggleMasterSMPTE:  KeyBinding(character: "m", keyCode: 46),
        .toggleRow1SMPTE:    KeyBinding(character: "f1", keyCode: 122),
        .toggleRow2SMPTE:    KeyBinding(character: "f2", keyCode: 120),
        .toggleRow3SMPTE:    KeyBinding(character: "f3", keyCode: 99),
        .toggleRow4SMPTE:    KeyBinding(character: "f4", keyCode: 118),
        .toggleFocusedSMPTE: KeyBinding(character: "q", keyCode: 12),
        .toggleLTCFollow:    KeyBinding(character: "f", keyCode: 3),
        .toggleResolume:     KeyBinding(character: "r", keyCode: 15),
        .toggleWebMonitor:   KeyBinding(character: "w", keyCode: 13),
    ]

    init() {
        load()
    }

    deinit {
        stop()
    }

    func attach(outputs: OutputController) {
        self.outputs = outputs
        // Si setVisibleRows corrió antes del attach, reenvía el filtro Dual/SMPTE.
        if !visibleRowIDs.isEmpty {
            outputs.setVisibleDeckIDs(visibleRowIDs)
        }
    }

    func setVisibleRows(_ ids: [String]) {
        if visibleRowIDs != ids { visibleRowIDs = ids }
        outputs?.setVisibleDeckIDs(ids)
    }

    func start() {
        guard !started else { return }
        started = true
        installKeyMonitor()
        openMIDI()
        refreshSources()
        reconnectMIDI()
    }

    func stop(forProcessExit: Bool = false) {
        started = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        cancelLearn()
        disconnectMIDI()
        // En salida de proceso, dispose de CoreMIDI suele colgar willTerminate.
        if forProcessExit {
            midiPort = 0
            midiClient = 0
            return
        }
        if midiPort != 0 { MIDIPortDispose(midiPort); midiPort = 0 }
        if midiClient != 0 { MIDIClientDispose(midiClient); midiClient = 0 }
    }

    // MARK: Persistencia

    func resetToDefaults() {
        keyBindings = Self.defaultKeyBindings
        midiBindings = [:]
        cancelLearn()
        persist()
    }

    func clearMIDI(_ action: MappingAction) {
        midiBindings[action] = nil
        persist()
    }

    func clearKey(_ action: MappingAction) {
        keyBindings[action] = nil
        persist()
    }

    func beginLearnMIDI(_ action: MappingAction) {
        learning = .midi(action)
        scheduleLearnTimeout()
    }

    func beginLearnKey(_ action: MappingAction) {
        learning = .key(action)
        scheduleLearnTimeout()
    }

    func cancelLearn() {
        learning = nil
        learnTimeout?.cancel()
        learnTimeout = nil
    }

    private func scheduleLearnTimeout() {
        learnTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.learning = nil
        }
        learnTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.keysDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            var map: [MappingAction: KeyBinding] = [:]
            for (raw, binding) in decoded {
                if let action = MappingAction(rawValue: raw) {
                    map[action] = binding
                }
            }
            for (action, binding) in Self.defaultKeyBindings where map[action] == nil {
                map[action] = binding
            }
            // Migración teclas antiguas Dual/Auto → Auto/Denon/Pioneer/Todos.
            let oldModes: [MappingAction: KeyBinding] = [
                .modeAuto:    KeyBinding(character: "2", keyCode: 19),
                .modeDenon:   KeyBinding(character: "3", keyCode: 20),
                .modePioneer: KeyBinding(character: "4", keyCode: 21),
                .modeTodos:   KeyBinding(character: "5", keyCode: 23),
            ]
            if oldModes.allSatisfy({ map[$0.key] == $0.value }) {
                for (action, binding) in Self.defaultKeyBindings where oldModes[action] != nil {
                    map[action] = binding
                }
                keyBindings = map
                persist()
            } else {
                keyBindings = map
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.midiDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: MIDIBinding].self, from: data) {
            var map: [MappingAction: MIDIBinding] = [:]
            for (raw, binding) in decoded {
                if let action = MappingAction(rawValue: raw) {
                    map[action] = binding
                }
            }
            midiBindings = map
        }
        selectedSourceID = UserDefaults.standard.string(forKey: Self.sourceDefaultsKey) ?? ""
    }

    private func persist() {
        let keys = Dictionary(uniqueKeysWithValues: keyBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: Self.keysDefaultsKey)
        }
        let midi = Dictionary(uniqueKeysWithValues: midiBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(midi) {
            UserDefaults.standard.set(data, forKey: Self.midiDefaultsKey)
        }
        UserDefaults.standard.set(selectedSourceID, forKey: Self.sourceDefaultsKey)
    }

    // MARK: Ejecutar

    func perform(_ action: MappingAction, force: MappingForce = .toggle) {
        switch action {
        case .modeAuto:    mode = .auto; if !allSourcesEnabled { setAllSources(true) }
        case .modeDenon:   mode = .denon
        case .modePioneer: mode = .pioneer
        case .modeTodos:   mode = .todos; setAllSources(true)
        case .layoutLarge: layout = .large
        case .layoutSmall: layout = .small
        case .layoutMaster: layout = .master
        case .zoomIn:
            if Self.keyWindowIsMonitor {
                monitorWaveformWindowSeconds = WaveformZoom.zoomIn(monitorWaveformWindowSeconds)
            } else {
                waveformWindowSeconds = WaveformZoom.zoomIn(waveformWindowSeconds)
            }
        case .zoomOut:
            if Self.keyWindowIsMonitor {
                monitorWaveformWindowSeconds = WaveformZoom.zoomOut(monitorWaveformWindowSeconds)
            } else {
                waveformWindowSeconds = WaveformZoom.zoomOut(waveformWindowSeconds)
            }
        case .toggleConfig:
            applyToggle(&showOutputs, force: force)
        case .toggleLog:
            applyToggle(&showLog, force: force)
        case .toggleMasterSMPTE:
            guard let outputs else { return }
            switch force {
            case .off: if outputs.ltcEnabled { outputs.stopMasterLTC() }
            case .on:  if !outputs.ltcEnabled { outputs.enableMasterAutoFollow() }
            case .toggle: outputs.toggleLTC()
            }
        case .toggleRow1SMPTE:    toggleVisibleRow(0, force: force)
        case .toggleRow2SMPTE:    toggleVisibleRow(1, force: force)
        case .toggleRow3SMPTE:    toggleVisibleRow(2, force: force)
        case .toggleRow4SMPTE:    toggleVisibleRow(3, force: force)
        case .toggleFocusedSMPTE: toggleFocusedRow(force: force)
        case .toggleRow1Lock:     toggleVisibleLock(0, force: force)
        case .toggleRow2Lock:     toggleVisibleLock(1, force: force)
        case .toggleRow3Lock:     toggleVisibleLock(2, force: force)
        case .toggleRow4Lock:     toggleVisibleLock(3, force: force)
        case .toggleFocusedLock:  toggleFocusedLock(force: force)
        case .toggleLTCFollow:
            if Self.keyWindowIsMonitor {
                NotificationCenter.default.post(name: .scMonitorToggleFullscreen, object: nil)
                return
            }
            guard let outputs else { return }
            switch force {
            case .off: outputs.setAutoFollow(false)
            case .on:  outputs.setAutoFollow(true)
            case .toggle: outputs.setAutoFollow(!outputs.ltcAutoFollow)
            }
        case .toggleResolume:
            guard let outputs else { return }
            applyOutputToggle(isOn: outputs.resolumeEnabled, force: force) {
                outputs.toggleResolume()
            }
        case .toggleWebMonitor:
            guard let outputs else { return }
            applyOutputToggle(isOn: outputs.webEnabled, force: force) {
                outputs.toggleWebServer()
            }
        }
    }

    private func applyToggle(_ value: inout Bool, force: MappingForce) {
        switch force {
        case .off: value = false
        case .on:  value = true
        case .toggle: value.toggle()
        }
    }

    private func applyOutputToggle(isOn: Bool, force: MappingForce, toggle: () -> Void) {
        switch force {
        case .off: if isOn { toggle() }
        case .on:  if !isOn { toggle() }
        case .toggle: toggle()
        }
    }

    private func toggleVisibleRow(_ index: Int, force: MappingForce) {
        guard let id = visibleRowID(index) else { return }
        applyRowLTC(id, force: force)
    }

    private func toggleFocusedRow(force: MappingForce) {
        guard let outputs else { return }
        let id = outputs.ltcSourceDeckID
            ?? outputs.hotDeckID
            ?? outputs.ltcFollowedDeckID
            ?? visibleRowIDs.first
            ?? outputs.ltcDeckSlots.first?.id
        guard let id else { return }
        applyRowLTC(id, force: force)
    }

    private func applyRowLTC(_ id: String, force: MappingForce) {
        guard let outputs else { return }
        switch force {
        case .off:
            if outputs.isDeckLTCEnabled(id) || outputs.isRowLTCLit(id) {
                outputs.toggleRowLTC(id)
            }
        case .on:
            if !outputs.isRowLTCLit(id) { outputs.toggleRowLTC(id) }
        case .toggle:
            outputs.toggleRowLTC(id)
        }
    }

    private func toggleVisibleLock(_ index: Int, force: MappingForce) {
        guard let id = visibleRowID(index) else { return }
        applyRowLock(id, force: force)
    }

    private func toggleFocusedLock(force: MappingForce) {
        guard let outputs else { return }
        let id = outputs.ltcSourceDeckID
            ?? outputs.hotDeckID
            ?? outputs.ltcFollowedDeckID
            ?? visibleRowIDs.first
            ?? outputs.ltcDeckSlots.first?.id
        guard let id else { return }
        applyRowLock(id, force: force)
    }

    /// F1–F4 = primeras 4 filas visibles (id estable), no el índice de CONFIG.
    private func visibleRowID(_ index: Int) -> String? {
        if index < visibleRowIDs.count { return visibleRowIDs[index] }
        guard let outputs, index < outputs.ltcDeckSlots.count else { return nil }
        return outputs.ltcDeckSlots[index].id
    }

    private func applyRowLock(_ id: String, force: MappingForce) {
        guard let outputs else { return }
        switch force {
        case .off: outputs.setDeckLocked(id, locked: false)
        case .on:  outputs.setDeckLocked(id, locked: true)
        case .toggle: outputs.toggleDeckLock(id)
        }
    }

    func rowLabel(_ index: Int) -> String {
        guard let id = visibleRowID(index) else { return "sin fila" }
        if let outputs, let slot = outputs.ltcDeckSlots.first(where: { OutputController.sameDeckID($0.id, id) }) {
            return slot.label
        }
        return id
    }

    // MARK: Teclado

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.isARepeat { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return event }

        if case .key(let action) = learning {
            if event.keyCode == 53 {
                cancelLearn()
                return nil
            }
            if Self.isTyping() { return event }
            guard let binding = KeyBinding.from(event: event), binding.character != "esc" else {
                return event
            }
            assignKey(binding, to: action)
            return nil
        }

        if Self.isTyping() { return event }

        if Self.keyWindowIsMonitor {
            if event.keyCode == 53 {
                NotificationCenter.default.post(name: .scMonitorEscape, object: nil)
                return nil
            }
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if ch == "f", flags.isEmpty {
                NotificationCenter.default.post(name: .scMonitorToggleFullscreen, object: nil)
                return nil
            }
        }

        if !keyboardEnabled && learning == nil {
            if event.keyCode == 53, showOutputs {
                showOutputs = false
                return nil
            }
            return event
        }

        if event.keyCode == 53 {
            if learning != nil {
                cancelLearn()
                return nil
            }
            if showOutputs {
                showOutputs = false
                return nil
            }
            return event
        }

        for (action, binding) in keyBindings {
            if binding.matches(event) {
                perform(action)
                return nil
            }
        }
        let ch = event.charactersIgnoringModifiers ?? ""
        if ch == "+" || ch == "=" {
            perform(.zoomIn)
            return nil
        }
        if ch == "-" || ch == "_" {
            perform(.zoomOut)
            return nil
        }
        return event
    }

    private func assignKey(_ binding: KeyBinding, to action: MappingAction) {
        for (other, existing) in keyBindings where other != action {
            if existing.character == binding.character {
                keyBindings[other] = nil
            }
        }
        keyBindings[action] = binding
        cancelLearn()
        persist()
    }

    static var keyWindowIsMonitor: Bool {
        guard let window = NSApp.keyWindow else { return false }
        if window.identifier?.rawValue == "sc-monitor" { return true }
        return window.title.localizedCaseInsensitiveContains("Monitor")
    }

    static func isTyping() -> Bool {
        guard let resp = NSApp.keyWindow?.firstResponder else { return false }
        if resp is NSTextView || resp is NSTextField || resp is NSText { return true }
        if let view = resp as? NSView {
            return view.enclosingScrollView?.documentView is NSTextView
        }
        return false
    }

    // MARK: MIDI

    func selectSource(_ id: String) {
        selectedSourceID = id
        persist()
        reconnectMIDI()
    }

    func refreshSources() {
        var list: [MIDISourceInfo] = []
        let n = MIDIGetNumberOfSources()
        if n > 0 {
            for i in 0..<n {
                let endpoint = MIDIGetSource(i)
                if endpoint == 0 { continue }
                var uid: Int32 = 0
                MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
                var cfName: Unmanaged<CFString>?
                var name = "Puerto \(i + 1)"
                if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cfName) == noErr,
                   let cfName {
                    name = cfName.takeRetainedValue() as String
                } else if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfName) == noErr,
                          let cfName {
                    name = cfName.takeRetainedValue() as String
                }
                list.append(MIDISourceInfo(id: String(uid), name: name, uniqueID: uid))
            }
        }
        sources = list
        if list.isEmpty {
            midiStatus = "Sin entradas MIDI. Conecta un controlador o activa IAC en Audio MIDI Setup."
        } else if selectedSourceID.isEmpty {
            midiStatus = "Usando el primer puerto: \(list[0].name)"
        } else if let chosen = list.first(where: { $0.id == selectedSourceID }) {
            midiStatus = "Puerto: \(chosen.name)"
        } else {
            midiStatus = "El puerto guardado no está. Se usa el primero."
        }
    }

    private func openMIDI() {
        guard midiClient == 0 else { return }
        let status = MIDIClientCreateWithBlock("STAGE CONNECT MAP" as CFString, &midiClient) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshSources()
                self?.reconnectMIDI()
            }
        }
        guard status == noErr else {
            midiStatus = "No se pudo abrir CoreMIDI (\(status))"
            return
        }
        let portStatus = MIDIInputPortCreateWithBlock(
            midiClient, "STAGE CONNECT MAP IN" as CFString, &midiPort
        ) { [weak self] pktList, _ in
            self?.ingest(pktList)
        }
        if portStatus != noErr {
            midiStatus = "No se pudo crear el puerto MIDI (\(portStatus))"
        }
    }

    func reconnectMIDI() {
        disconnectMIDI()
        guard midiPort != 0 else { return }
        refreshSources()
        let n = MIDIGetNumberOfSources()
        guard n > 0 else { return }

        var targetUID: Int32?
        if !selectedSourceID.isEmpty, let uid = Int32(selectedSourceID) {
            targetUID = uid
        }

        var connected = false
        for i in 0..<n {
            let endpoint = MIDIGetSource(i)
            if endpoint == 0 { continue }
            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            if let targetUID, uid != targetUID { continue }
            if MIDIPortConnectSource(midiPort, endpoint, nil) == noErr {
                connectedSources.append(endpoint)
                connected = true
                if targetUID == nil { break }
            }
            if targetUID != nil { break }
        }
        if !connected, targetUID != nil, n > 0 {
            let endpoint = MIDIGetSource(0)
            if endpoint != 0, MIDIPortConnectSource(midiPort, endpoint, nil) == noErr {
                connectedSources.append(endpoint)
            }
        }
    }

    private func disconnectMIDI() {
        for src in connectedSources {
            MIDIPortDisconnectSource(midiPort, src)
        }
        connectedSources.removeAll()
    }

    private func ingest(_ pktList: UnsafePointer<MIDIPacketList>) {
        // MIDIPacketNext sobre una copia en pila apunta fuera de la lista
        // (length puede ser >256). Iterar la secuencia real del paquete.
        for packet in pktList.unsafeSequence() {
            let len = Int(packet.pointee.length)
            guard len > 0 else { continue }
            let bytes: [UInt8] = withUnsafePointer(to: packet.pointee.data) { dataPtr in
                let raw = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
                let n = min(len, 1024)
                return Array(UnsafeBufferPointer(start: raw, count: n))
            }
            DispatchQueue.main.async { [weak self] in
                self?.handleMIDI(bytes)
            }
        }
    }

    private func handleMIDI(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var i = 0
        var running: UInt8 = 0
        while i < bytes.count {
            var status = bytes[i]
            if status < 0x80 {
                if running == 0 { break }
                status = running
            } else {
                i += 1
                if status < 0xF0 { running = status } else { running = 0 }
            }
            let type = status & 0xF0
            let channel = status & 0x0F
            switch type {
            case 0x90, 0x80:
                guard i + 1 < bytes.count else { return }
                let note = bytes[i]
                let vel = bytes[i + 1]
                i += 2
                let on = type == 0x90 && vel > 0
                if on {
                    receive(MIDIBinding(kind: "note", channel: channel, number: note), value: vel)
                }
            case 0xB0:
                guard i + 1 < bytes.count else { return }
                let cc = bytes[i]
                let value = bytes[i + 1]
                i += 2
                receive(MIDIBinding(kind: "cc", channel: channel, number: cc), value: value)
            case 0xA0, 0xE0:
                guard i + 1 < bytes.count else { return }
                i += 2
            case 0xC0, 0xD0:
                guard i < bytes.count else { return }
                i += 1
            default:
                if type >= 0xF0 { return }
                i += 1
            }
        }
    }

    private func receive(_ binding: MIDIBinding, value: UInt8) {
        lastMIDILabel = "\(binding.label)  val \(value)"
        if case .midi(let action) = learning {
            for (other, existing) in midiBindings where other != action && existing == binding {
                midiBindings[other] = nil
            }
            midiBindings[action] = binding
            cancelLearn()
            persist()
            return
        }

        guard midiEnabled else { return }
        guard let action = midiBindings.first(where: { $0.value == binding })?.key else { return }
        let force: MappingForce
        if binding.kind == "cc" {
            if value == 0 {
                force = action.supportsOff ? .off : .toggle
                if !action.supportsOff { return }
            } else if value > 64 {
                force = .toggle
            } else {
                return
            }
        } else {
            force = .toggle
        }
        perform(action, force: force)
    }
}
