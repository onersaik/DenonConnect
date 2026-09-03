// LTCGenerator.swift
// Generador de SMPTE LTC (Linear Timecode) por salida de audio.
// Admite selección de dispositivo CoreAudio: BlackHole, Loopback, salida física…

import Foundation
import AVFoundation
import CoreAudio

// MARK: - Info de dispositivo de audio

public struct AudioDeviceInfo: Identifiable, Equatable {
    public let id: AudioDeviceID      // kAudioObjectUnknown = 0 → dispositivo por defecto
    public let name: String
    public var isDefault: Bool

    public static let systemDefault = AudioDeviceInfo(id: 0, name: "Dispositivo por defecto del sistema", isDefault: true)
}

// MARK: - LTCGenerator

public final class LTCGenerator {

    // MARK: Tipos públicos

    public enum FrameRate: Double, CaseIterable {
        case fps24 = 24
        case fps25 = 25
        case fps30 = 30

        public var label: String {
            switch self {
            case .fps24: return "24 fps"
            case .fps25: return "25 fps (PAL)"
            case .fps30: return "30 fps"
            }
        }
    }

    public enum LTCError: Error, CustomStringConvertible {
        case formatUnavailable
        case deviceNotFound
        public var description: String {
            switch self {
            case .formatUnavailable: return "no se pudo preparar el formato de audio"
            case .deviceNotFound:    return "el dispositivo de audio seleccionado no está disponible"
            }
        }
    }

    // MARK: Propiedades configurables

    public var frameRate: FrameRate  = .fps25
    public var level:     Float      = 0.5
    /// nil → usa el dispositivo por defecto del sistema
    public var outputDeviceID: AudioDeviceID? = nil

    // MARK: Privado

    private var engine     = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let log:        (String) -> Void
    private let name:       String
    private let stateLock  = NSLock()

    private var currentFrame:       Int    = 0
    private var running             = false
    private var paused              = true
    /// Segundos de playhead anclados por el tick. No es un reloj de pared.
    private var playheadSeconds:    Double = 0
    /// Velocidad real medida del reproductor (1.0 = normal). El tono LTC
    /// generado tiene que sonar mas rapido/lento exactamente igual que un
    /// tape vari-speed cuando el DJ cambia el pitch — no solo la cifra en
    /// pantalla, tambien el audio SMPTE que sale hacia luces/video externos.
    private var playbackRate:       Double = 1.0
    private var rateRefWallClock:   Double = 0
    private var rateRefSeconds:     Double = 0
    private var bitsOfFrame:        [UInt8] = []
    private var bitIndex:           Int    = 0
    private var halfBitPhase:       Int    = 0
    private var samplesIntoHalfBit: Double = 0
    private var polarity:           Float  = 1
    private var sampleRate:         Double = 48000

    public init(name: String = "LTC", log: @escaping (String) -> Void = { _ in }) {
        self.name = name
        self.log = log
    }

    deinit { stop() }

    // MARK: Estado

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    // MARK: Enumeración de dispositivos

    /// Devuelve todos los dispositivos de salida de audio disponibles más la
    /// opción "por defecto del sistema" en primer lugar.
    public static func availableOutputDevices() -> [AudioDeviceInfo] {
        var result: [AudioDeviceInfo] = [.systemDefault]
        #if os(macOS)
        // Obtener lista de todos los objetos de audio
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize) == noErr, dataSize > 0
        else { return result }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize, &deviceIDs) == noErr
        else { return result }

        // Dispositivo de salida por defecto del sistema
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var defaultID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr, 0, nil, &defaultSize, &defaultID)

        for deviceID in deviceIDs {
            // Comprobar que tiene canales de salida
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope:    kAudioDevicePropertyScopeOutput,
                mElement:  kAudioObjectPropertyElementMain
            )
            var outSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &outAddr, 0, nil, &outSize) == noErr,
                  outSize > 0 else { continue }

            // Obtener el nombre
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr
            else { continue }

            let name = nameRef as String
            guard !name.isEmpty else { continue }
            result.append(AudioDeviceInfo(
                id:        deviceID,
                name:      name,
                isDefault: deviceID == defaultID
            ))
        }
        #endif
        return result
    }

    // MARK: Control

    public func seek(toSeconds seconds: Double) {
        applyPlayhead(seconds: seconds, playing: nil, force: true)
    }

    public func currentFrameNumber() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return currentFrame
    }

    /// El LTC es el playhead de la pista: 0 → 00:00:00:00, seek/jog/cue
    /// clavan el frame en el acto. `playing == false` congela (silencio).
    /// En play, el reloj de audio avanza; solo hard-reset si seek, pause/play
    /// o `force` (fan-out unificando engines desfasados).
    public func applyPlayhead(seconds: Double, playing: Bool? = nil, force: Bool = false, rateHint: Double? = nil) {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        let wasPlaying = !paused
        if let playing { paused = !playing }
        let nowPlaying = !paused
        let frame = Self.frameNumber(seconds: safe, fps: frameRate.rawValue)
        let delta = frame - currentFrame
        let playStateChanged = wasPlaying != nowPlaying
        // Pausa: cualquier movimiento es jog/seek → clava el frame.
        // Play: una pequeña desviación no resetea el flujo de bits (eso es
        // lo que sonaba a "saltos" — cada hard-reset reinicia la fase del
        // tono LTC a medio bit, un click audible). Solo se resetea con un
        // desfase grande de verdad (seek/cue real), no por el jitter normal
        // entre la posición interpolada y el reloj de audio.
        let pausedSeek = !nowPlaying && delta != 0
        let hardReset = force || bitsOfFrame.isEmpty || playStateChanged
            || pausedSeek || abs(delta) > 6
        if hardReset {
            playheadSeconds = safe
            currentFrame = max(0, frame)
            loadFrameBitsLocked()
            rateRefWallClock = now
            rateRefSeconds = safe
            if rateHint == nil { playbackRate = 1.0 }
        }
        // Velocidad del tono LTC: el protocolo manda el pitch/vari-speed
        // real (StageLinq /Speed, Pro DJ Link % pitch), pero esa lectura
        // incluye el ruido normal de tocar el jog wheel o pequeños ajustes
        // de beatgrid, no solo el fader de pitch — usarla en crudo produce
        // saltos audibles de velocidad. Se suaviza igual que la estimación
        // por diferencia, para que un cambio real de pitch se note enseguida
        // pero un jitter de 1 frame no.
        let smoothing = 0.82
        if let hint = rateHint, hint.isFinite, hint > 0 {
            let clamped = min(4.0, max(-4.0, hint))
            playbackRate = playbackRate * smoothing + clamped * (1 - smoothing)
        } else if nowPlaying, !hardReset {
            let dtWall = now - rateRefWallClock
            let dtSeconds = safe - rateRefSeconds
            if rateRefWallClock > 0, dtWall >= 0.05, abs(dtSeconds) > 0.0004 {
                let measured = dtSeconds / dtWall
                if measured.isFinite {
                    let clamped = min(4.0, max(-4.0, measured))
                    playbackRate = playbackRate * smoothing + clamped * (1 - smoothing)
                }
                rateRefWallClock = now
                rateRefSeconds = safe
            }
        }
        stateLock.unlock()
    }

    /// Con la pista en pausa el LTC se congela en el frame actual (silencio,
    /// sin avanzar). Al reanudar sigue desde el playhead.
    public func setPaused(_ value: Bool) {
        stateLock.lock()
        paused = value
        stateLock.unlock()
    }

    public func start() throws {
        stateLock.lock()
        let already = running
        stateLock.unlock()
        if already { stop() }

        engine = AVAudioEngine()

        // Seleccionar dispositivo si el usuario eligió uno específico
        if let deviceID = outputDeviceID, deviceID != 0 {
            try setOutputDevice(deviceID)
        }

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let rate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48000

        stateLock.lock()
        sampleRate = rate
        // No resetear a 00:00:00:00: applyPlayhead ya dejó el frame del deck.
        if bitsOfFrame.isEmpty {
            currentFrame = Self.frameNumber(seconds: playheadSeconds, fps: frameRate.rawValue)
            loadFrameBitsLocked()
        }
        running = true
        paused = true
        stateLock.unlock()

        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        guard let format else { throw LTCError.formatUnavailable }

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            self.render(into: buffers, frameCount: Int(frameCount))
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()

        let deviceDesc: String
        if let id = outputDeviceID, id != 0 {
            deviceDesc = "device \(id)"
        } else {
            deviceDesc = "dispositivo por defecto"
        }
        log("SMPTE LTC [\(name)] en marcha — \(Int(frameRate.rawValue)) fps, \(Int(rate)) Hz, \(deviceDesc)")
    }

    /// Corta el engine, el AU y el render. No deja silencio a 00:00:00:00:
    /// deja de emitir por completo.
    public func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        paused = true
        bitsOfFrame = []
        bitIndex = 0
        halfBitPhase = 0
        samplesIntoHalfBit = 0
        stateLock.unlock()

        if let node = sourceNode {
            engine.mainMixerNode.outputVolume = 0
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sourceNode = nil
        }
        if engine.isRunning { engine.stop() }
        engine.reset()
        if wasRunning { log("SMPTE LTC [\(name)] detenido") }
    }

    // MARK: Timecode legible

    public func currentPositionSeconds() -> Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return playheadSeconds
    }

    public func currentTimecodeText() -> String {
        stateLock.lock()
        let seconds = playheadSeconds
        let fps = frameRate.rawValue
        stateLock.unlock()
        return Self.timecodeText(seconds: seconds, fps: fps)
    }

    public static func frameNumber(seconds: Double, fps: Double) -> Int {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let rate = fps > 0 ? fps : 25
        return max(0, Int(safe * rate))
    }

    public static func timecodeText(seconds: Double, fps: Double) -> String {
        let n = Int(fps > 0 ? fps : 25)
        let frame = frameNumber(seconds: seconds, fps: Double(n))
        let frames = n > 0 ? frame % n : 0
        let totalSec = n > 0 ? frame / n : 0
        return String(format: "%02d:%02d:%02d:%02d",
                      (totalSec / 3600) % 24, (totalSec / 60) % 60,
                      totalSec % 60, frames)
    }

    // MARK: Selección de dispositivo CoreAudio

    private func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        #if os(macOS)
        guard let audioUnit = engine.outputNode.audioUnit else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw LTCError.deviceNotFound
        }
        #endif
    }

    // MARK: Render de audio

    private func render(into buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        stateLock.lock()
        let isRunning  = running
        let isPaused   = paused
        let rate       = sampleRate
        let amplitude  = level
        let rawRate    = playbackRate
        stateLock.unlock()

        guard isRunning else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return
        }

        if isPaused {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return
        }

        // El tono LTC tiene que sonar mas rapido/lento con el pitch real del
        // reproductor, igual que un cabezal de cinta vari-speed: se varia el
        // ritmo de bit (samplesPerHalfBit), no solo un contador cosmetico.
        // Un reproductor yendo hacia atras (rawRate <= 0, backspin) no se
        // puede codificar como LTC invertido de forma fiable: se congela el
        // tono (no se generan bits nuevos) hasta que retoma marcha adelante,
        // y ahi el propio applyPlayhead clava la posicion correcta al vuelo.
        let effectiveRate = min(4.0, max(0.05, rawRate))
        let frozen = rawRate <= 0.05
        let bitsPerSecond      = frameRate.rawValue * 80.0
        let samplesPerHalfBit  = frozen
            ? Double.greatestFiniteMagnitude
            : (rate / (bitsPerSecond * 2.0)) / effectiveRate
        let dt = (rate > 0 && !frozen) ? effectiveRate / rate : 0
        var samples = [Float](repeating: 0, count: frameCount)

        stateLock.lock()
        for i in 0..<frameCount {
            samples[i] = polarity * amplitude
            guard !frozen else { continue }
            playheadSeconds += dt
            samplesIntoHalfBit += 1
            if samplesIntoHalfBit >= samplesPerHalfBit {
                samplesIntoHalfBit -= samplesPerHalfBit
                advanceHalfBitLocked()
            }
        }
        stateLock.unlock()

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let ptr = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount { ptr[i] = samples[i] }
        }
    }

    private func advanceHalfBitLocked() {
        if halfBitPhase == 0 {
            if bitIndex < bitsOfFrame.count, bitsOfFrame[bitIndex] == 1 { polarity = -polarity }
            halfBitPhase = 1
        } else {
            polarity = -polarity
            halfBitPhase = 0
            bitIndex += 1
            if bitIndex >= bitsOfFrame.count {
                currentFrame = Self.frameNumber(seconds: playheadSeconds, fps: frameRate.rawValue)
                loadFrameBitsLocked()
            }
        }
    }

    private func loadFrameBitsLocked() {
        bitsOfFrame = LTCGenerator.encodeFrame(frameNumber: currentFrame, frameRate: frameRate.rawValue)
        bitIndex = 0; halfBitPhase = 0; samplesIntoHalfBit = 0
    }

    // MARK: Codificación de frame LTC

    public static func encodeFrame(frameNumber: Int, frameRate: Double) -> [UInt8] {
        let fps = Int(frameRate)
        let totalFrames = max(0, frameNumber)
        let frames  = totalFrames % fps
        let totalSec = totalFrames / fps
        let seconds = totalSec % 60
        let minutes = (totalSec / 60) % 60
        let hours   = (totalSec / 3600) % 24

        var bits = [UInt8](repeating: 0, count: 80)
        func write(_ v: Int, at offset: Int, count: Int) {
            for i in 0..<count { bits[offset + i] = UInt8((v >> i) & 1) }
        }
        write(frames  % 10, at: 0,  count: 4)
        write(frames  / 10, at: 8,  count: 2)
        write(seconds % 10, at: 16, count: 4)
        write(seconds / 10, at: 24, count: 3)
        write(minutes % 10, at: 32, count: 4)
        write(minutes / 10, at: 40, count: 3)
        write(hours   % 10, at: 48, count: 4)
        write(hours   / 10, at: 56, count: 2)
        let sync: [UInt8] = [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,1]
        for (i, b) in sync.enumerated() { bits[64 + i] = b }
        return bits
    }
}

// MARK: - Fan-out: un LTC → N dispositivos

/// Un único playhead/pause/seek alimenta N `LTCGenerator` (un engine por salida).
/// El mismo bitstream en dos devices es correcto. Apagar = stop de todos.
/// Si un AU se desfasó, el tick unifica seek en todos los engines de esta fuente.
public final class LTCFanout {

    public let name: String
    public var frameRate: LTCGenerator.FrameRate = .fps25
    public var level: Float = 0.5

    private var gens: [LTCGenerator] = []
    private let log: (String) -> Void

    public init(name: String, log: @escaping (String) -> Void = { _ in }) {
        self.name = name
        self.log = log
    }

    deinit { stop() }

    public var isRunning: Bool {
        gens.contains { $0.isRunning }
    }

    public var outputCount: Int { gens.count }

    public func start(deviceIDs: [AudioDeviceID], playhead: Double?, playing: Bool) throws {
        stop()
        let unique = Self.uniqueIDs(deviceIDs)
        let head = Self.clampedPlayhead(playhead)
        var started: [LTCGenerator] = []
        do {
            for (i, id) in unique.enumerated() {
                let label = unique.count > 1 ? "\(name)#\(i + 1)" : name
                let gen = LTCGenerator(name: label, log: log)
                gen.frameRate = frameRate
                gen.level = level
                gen.outputDeviceID = id == 0 ? nil : id
                // Primer frame = posición real (0 → 00:00:00:00), no un reloj de pared.
                gen.applyPlayhead(seconds: head, playing: false, force: true)
                try gen.start()
                gen.applyPlayhead(seconds: head, playing: playing, force: true)
                started.append(gen)
            }
            gens = started
            if unique.count > 1 {
                log("SMPTE LTC [\(name)] × \(unique.count) salidas — mismo playhead")
            }
        } catch {
            started.forEach {
                $0.setPaused(true)
                $0.stop()
            }
            throw error
        }
    }

    public func stop() {
        gens.forEach {
            $0.setPaused(true)
            $0.stop()
        }
        gens.removeAll()
    }

    /// Mismo seek/pause/play en todos los engines. Si uno se desfasó, unifica.
    public func applyPlayhead(seconds: Double, playing: Bool, rateHint: Double? = nil) {
        let head = Self.clampedPlayhead(seconds)
        let unify = needsUnify(targetSeconds: head)
        for gen in gens {
            gen.applyPlayhead(seconds: head, playing: playing, force: unify, rateHint: rateHint)
        }
    }

    public func setPaused(_ value: Bool) {
        gens.forEach { $0.setPaused(value) }
    }

    /// 0 si no hay playhead: el primer frame es 00:00:00:00, no un TC inventado.
    public static func clampedPlayhead(_ seconds: Double?) -> Double {
        guard let seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    /// Engines del mismo fan-out: mismo frame. Un AU atrasado arrastra a todos.
    func needsUnify(targetSeconds: Double) -> Bool {
        guard gens.count > 1 else { return false }
        let fps = frameRate.rawValue > 0 ? frameRate.rawValue : 25
        let targetFrame = LTCGenerator.frameNumber(seconds: targetSeconds, fps: fps)
        let frameSlack = 2
        let timeSlack = 2.0 / fps
        var minF = Int.max
        var maxF = Int.min
        var minT = Double.greatestFiniteMagnitude
        var maxT = -Double.greatestFiniteMagnitude
        for gen in gens {
            let t = gen.currentPositionSeconds()
            let f = gen.currentFrameNumber()
            minF = min(minF, f)
            maxF = max(maxF, f)
            minT = min(minT, t)
            maxT = max(maxT, t)
            if abs(f - targetFrame) > frameSlack { return true }
            if abs(t - targetSeconds) > timeSlack { return true }
        }
        if maxF - minF > 1 { return true }
        if maxT - minT > (1.5 / fps) { return true }
        return false
    }

    public static func uniqueIDs(_ ids: [AudioDeviceID]) -> [AudioDeviceID] {
        var seen = Set<AudioDeviceID>()
        var out: [AudioDeviceID] = []
        for id in ids where seen.insert(id).inserted {
            out.append(id)
        }
        return out.isEmpty ? [0] : out
    }
}
