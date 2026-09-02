// MIDITimecodeGenerator.swift
// Genera MIDI Timecode (MTC) a traves de un puerto MIDI virtual de CoreMIDI.
// El cliente DAW (Ableton, Logic, QLab) ve el puerto "SC6000 Connect MTC"
// y lo puede seleccionar como fuente de timecode externo.
//
// Protocolo: Full-Frame SysEx cada frame + Quarter-Frame messages 2x por frame.

import Foundation
import CoreMIDI

// MARK: - MIDITimecodeGenerator

public final class MIDITimecodeGenerator {

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

        var sysExType: UInt8 {
            switch self {
            case .fps24: return 0x00
            case .fps25: return 0x20
            case .fps30: return 0x60
            }
        }
    }

    // MARK: Propiedades publicas

    public var frameRate: FrameRate = .fps25
    public var isRunning: Bool { stateLock.withLock { running } }

    // MARK: Privado

    private let log: (String) -> Void
    private let stateLock = NSLock()

    private var client:     MIDIClientRef   = 0
    private var source:     MIDIEndpointRef = 0
    private var running     = false
    private var timer:      Timer?

    private var currentFrame: Int = 0
    private var qfPiece:      Int = 0

    // MARK: Init / Deinit

    public init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    deinit { stop() }

    // MARK: Control

    public func start() throws {
        stateLock.lock()
        if running { stateLock.unlock(); return }
        stateLock.unlock()

        let clientStatus = MIDIClientCreateWithBlock(
            "SC6000Connect" as CFString, &client
        ) { _ in }
        guard clientStatus == noErr else {
            throw MTCError.clientCreateFailed(clientStatus)
        }

        let srcStatus = MIDISourceCreate(client, "SC6000 Connect MTC" as CFString, &source)
        guard srcStatus == noErr else {
            MIDIClientDispose(client)
            client = 0
            throw MTCError.sourceCreateFailed(srcStatus)
        }

        stateLock.lock()
        running = true
        stateLock.unlock()

        let interval = 1.0 / (frameRate.rawValue * 4.0)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sendNextQuarterFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        log("[MTC] Puerto virtual 'SC6000 Connect MTC' activo -- \(Int(frameRate.rawValue)) fps")
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()

        timer?.invalidate()
        timer = nil

        if source != 0 { MIDIEndpointDispose(source); source = 0 }
        if client != 0 { MIDIClientDispose(client);   client = 0 }

        if wasRunning { log("[MTC] Puerto virtual cerrado") }
    }

    public func seek(toSeconds seconds: Double) {
        stateLock.lock()
        currentFrame = max(0, Int(seconds * frameRate.rawValue))
        qfPiece = 0
        stateLock.unlock()
        sendFullFrame()
    }

    public func currentPositionSeconds() -> Double {
        stateLock.withLock { Double(currentFrame) / frameRate.rawValue }
    }

    // MARK: Envio de mensajes

    private func sendFullFrame() {
        stateLock.lock()
        let frame = currentFrame
        let fps   = frameRate
        stateLock.unlock()

        let tc = timecodeComponents(frame: frame, fps: fps)
        let hh = fps.sysExType | UInt8(tc.h & 0x1F)

        send(bytes: [0xF0, 0x7F, 0x7F, 0x01, 0x01,
                     hh, UInt8(tc.m & 0x3F), UInt8(tc.s & 0x3F), UInt8(tc.f & 0x1F),
                     0xF7])
    }

    private func sendNextQuarterFrame() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        let frame = currentFrame
        let piece = qfPiece
        let fps   = frameRate
        stateLock.unlock()

        let tc = timecodeComponents(frame: frame, fps: fps)
        let nibble: UInt8
        switch piece {
        case 0: nibble = UInt8(tc.f & 0x0F)
        case 1: nibble = UInt8((tc.f >> 4) & 0x01)
        case 2: nibble = UInt8(tc.s & 0x0F)
        case 3: nibble = UInt8((tc.s >> 4) & 0x03)
        case 4: nibble = UInt8(tc.m & 0x0F)
        case 5: nibble = UInt8((tc.m >> 4) & 0x03)
        case 6: nibble = UInt8(tc.h & 0x0F)
        case 7: nibble = UInt8(((tc.h >> 4) & 0x01) | Int(fps.sysExType >> 1))
        default: nibble = 0
        }
        send(bytes: [0xF1, (UInt8(piece) << 4) | (nibble & 0x0F)])

        stateLock.lock()
        qfPiece = (qfPiece + 1) % 8
        if qfPiece == 0 { currentFrame += 1 }
        stateLock.unlock()
    }

    private func send(bytes: [UInt8]) {
        guard source != 0 else { return }
        var b = bytes
        var pkt = MIDIPacketList()
        var ptr = MIDIPacketListInit(&pkt)
        ptr = MIDIPacketListAdd(&pkt, 1024, ptr, 0, b.count, &b)
        MIDIReceived(source, &pkt)
    }

    private struct TC { var h, m, s, f: Int }

    private func timecodeComponents(frame: Int, fps: FrameRate) -> TC {
        let n = Int(fps.rawValue)
        let t = frame / n
        return TC(h: (t / 3600) % 24, m: (t / 60) % 60, s: t % 60, f: frame % n)
    }

    // MARK: Errores

    public enum MTCError: Error, CustomStringConvertible {
        case clientCreateFailed(OSStatus)
        case sourceCreateFailed(OSStatus)
        public var description: String {
            switch self {
            case .clientCreateFailed(let s): return "no se pudo crear el cliente MIDI (OSStatus \(s))"
            case .sourceCreateFailed(let s): return "no se pudo crear la fuente MIDI virtual (OSStatus \(s))"
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
