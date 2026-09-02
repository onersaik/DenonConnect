// LTCGenerator.swift
// Generador de SMPTE LTC (Linear Timecode) por salida de audio.
//
// LTC es timecode codificado como señal de audio: cualquier app que acepte
// timecode por audio (Resolume, Millumin, QLab, Ableton con plugin, mesas de
// luces…) puede engancharse a la posición de reproducción del deck.
//
// Cómo funciona el formato:
//   · 80 bits por frame de vídeo (a 25 fps → 2000 bits/s).
//   · Codificación bifase-mark: hay transición al principio de cada bit, y
//     además una transición a mitad de bit si el bit es 1. Así la señal se
//     puede leer sin importar la polaridad ni el nivel.
//   · Los bits 64…79 son la palabra de sincronismo 0011111111111101, que marca
//     el final del frame y permite detectar el sentido de reproducción.
//   · Horas, minutos, segundos y frames van en BCD repartidos en campos de 4
//     bits, intercalados con bits de usuario.

import Foundation
import AVFoundation

public final class LTCGenerator {
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

    public var frameRate: FrameRate = .fps25
    public var level: Float = 0.5

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let log: (String) -> Void
    private let stateLock = NSLock()

    // Posición actual en frames de timecode, y estado del codificador.
    private var currentFrame: Int = 0
    private var running = false
    private var bitsOfFrame: [UInt8] = []
    private var bitIndex: Int = 0
    private var halfBitPhase: Int = 0     // 0 = primera mitad, 1 = segunda
    private var samplesIntoHalfBit: Double = 0
    private var polarity: Float = 1
    private var sampleRate: Double = 48000

    public init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    /// Pone el generador en una posición concreta (segundos desde el inicio de
    /// la pista). Se llama al arrancar y cuando el deck se va de sitio.
    public func seek(toSeconds seconds: Double) {
        stateLock.lock()
        currentFrame = max(0, Int(seconds * frameRate.rawValue))
        loadFrameBitsLocked()
        stateLock.unlock()
    }

    public func start() throws {
        stateLock.lock()
        if running { stateLock.unlock(); return }
        stateLock.unlock()

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let rate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48000

        stateLock.lock()
        sampleRate = rate
        loadFrameBitsLocked()
        running = true
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
        log("🎬 SMPTE LTC en marcha a \(Int(frameRate.rawValue)) fps, \(Int(rate)) Hz")
    }

    public func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()

        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        log("⏹ SMPTE LTC detenido")
    }

    public enum LTCError: Error, CustomStringConvertible {
        case formatUnavailable
        public var description: String { "no se pudo preparar el formato de audio" }
    }

    // MARK: - Render de audio

    private func render(into buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        stateLock.lock()
        let isRunning = running
        let rate = sampleRate
        let amplitude = level
        stateLock.unlock()

        guard isRunning else {
            for buffer in buffers {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return
        }

        // Duración en muestras de media casilla de bit.
        let bitsPerSecond = frameRate.rawValue * 80.0
        let samplesPerHalfBit = rate / (bitsPerSecond * 2.0)

        var samples = [Float](repeating: 0, count: frameCount)

        stateLock.lock()
        for i in 0..<frameCount {
            samples[i] = polarity * amplitude

            samplesIntoHalfBit += 1
            if samplesIntoHalfBit >= samplesPerHalfBit {
                samplesIntoHalfBit -= samplesPerHalfBit
                advanceHalfBitLocked()
            }
        }
        stateLock.unlock()

        // La misma señal por los dos canales.
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let pointer = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount { pointer[i] = samples[i] }
        }
    }

    /// Avanza media casilla de bit aplicando la regla del bifase-mark.
    private func advanceHalfBitLocked() {
        if halfBitPhase == 0 {
            // Mitad del bit: solo hay transición si el bit vale 1.
            if bitIndex < bitsOfFrame.count, bitsOfFrame[bitIndex] == 1 {
                polarity = -polarity
            }
            halfBitPhase = 1
        } else {
            // Fin del bit: siempre hay transición, y pasamos al siguiente bit.
            polarity = -polarity
            halfBitPhase = 0
            bitIndex += 1
            if bitIndex >= bitsOfFrame.count {
                currentFrame += 1
                loadFrameBitsLocked()
            }
        }
    }

    private func loadFrameBitsLocked() {
        bitsOfFrame = LTCGenerator.encodeFrame(frameNumber: currentFrame, frameRate: frameRate.rawValue)
        bitIndex = 0
        halfBitPhase = 0
        samplesIntoHalfBit = 0
    }

    // MARK: - Codificación de un frame LTC

    /// Devuelve los 80 bits de un frame, en orden de transmisión.
    public static func encodeFrame(frameNumber: Int, frameRate: Double) -> [UInt8] {
        let fps = Int(frameRate)
        let totalFrames = max(0, frameNumber)
        let frames = totalFrames % fps
        let totalSeconds = totalFrames / fps
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = (totalSeconds / 3600) % 24

        var bits = [UInt8](repeating: 0, count: 80)

        // Cada campo va en BCD y con el bit menos significativo primero.
        func write(_ value: Int, at offset: Int, count: Int) {
            for i in 0..<count {
                bits[offset + i] = UInt8((value >> i) & 1)
            }
        }

        write(frames % 10, at: 0, count: 4)    // unidades de frame
        write(frames / 10, at: 8, count: 2)    // decenas de frame
        write(seconds % 10, at: 16, count: 4)  // unidades de segundo
        write(seconds / 10, at: 24, count: 3)  // decenas de segundo
        write(minutes % 10, at: 32, count: 4)  // unidades de minuto
        write(minutes / 10, at: 40, count: 3)  // decenas de minuto
        write(hours % 10, at: 48, count: 4)    // unidades de hora
        write(hours / 10, at: 56, count: 2)    // decenas de hora
        // El resto de posiciones son bits de usuario y banderas: se dejan a 0.

        // Palabra de sincronismo, bits 64…79: 0011111111111101
        let sync: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        for (i, bit) in sync.enumerated() {
            bits[64 + i] = bit
        }

        return bits
    }

    /// Posición actual del generador en segundos, para corregir la deriva
    /// contra la posición real del deck.
    public func currentPositionSeconds() -> Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return Double(currentFrame) / frameRate.rawValue
    }

    /// Timecode legible de la posición actual, para mostrarlo en pantalla.
    public func currentTimecodeText() -> String {
        stateLock.lock()
        let frame = currentFrame
        stateLock.unlock()

        let fps = Int(frameRate.rawValue)
        let frames = frame % fps
        let totalSeconds = frame / fps
        return String(format: "%02d:%02d:%02d:%02d",
                      (totalSeconds / 3600) % 24,
                      (totalSeconds / 60) % 60,
                      totalSeconds % 60,
                      frames)
    }
}
