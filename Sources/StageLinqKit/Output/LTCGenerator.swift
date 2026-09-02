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
        return result
    }

    // MARK: Control

    public func seek(toSeconds seconds: Double) {
        applyPlayhead(seconds: seconds, playing: nil)
    }

    /// El LTC es el playhead de la pista: 0 → 00:00:00:00, seek/jog/cue
    /// clavan el frame en el acto. `playing == false` congela (silencio).
    /// Solo se reinicia el bitstream en un salto de más de un frame.
    public func applyPlayhead(seconds: Double, playing: Bool? = nil) {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        stateLock.lock()
        let wasPlaying = !paused
        if let playing { paused = !playing }
        let nowPlaying = !paused
        let frame = Self.frameNumber(seconds: safe, fps: frameRate.rawValue)
        let delta = frame - currentFrame
        let playStateChanged = wasPlaying != nowPlaying
        // Solo hard-reset en primera carga, cambio play/pause, o salto >2 frames.
        // Mientras reproduce con delta pequeno, el reloj de audio avanza sin resetear.
        let hardReset = bitsOfFrame.isEmpty || playStateChanged || abs(delta) > 2
        if hardReset {
            playheadSeconds = safe
            currentFrame = max(0, frame)
            loadFrameBitsLocked()
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

        engine.mainMixerNode.outputVolume = 0
        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sourceNode = nil
        }
        engine.stop()
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
    }

    // MARK: Render de audio

    private func render(into buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        stateLock.lock()
        let isRunning  = running
        let isPaused   = paused
        let rate       = sampleRate
        let amplitude  = level
        stateLock.unlock()

        guard isRunning else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return
        }

        if isPaused {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return
        }

        let bitsPerSecond      = frameRate.rawValue * 80.0
        let samplesPerHalfBit  = rate / (bitsPerSecond * 2.0)
        let dt = rate > 0 ? 1.0 / rate : 0
        var samples = [Float](repeating: 0, count: frameCount)

        stateLock.lock()
        for i in 0..<frameCount {
            samples[i] = polarity * amplitude
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
