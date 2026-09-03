// ProceduralWaveform.swift
// Genera peaks RGB procedurales deterministas a partir de un seed (hash del título).
// Simula la forma de onda de un track electrónico sin necesidad de FileTransfer.

import Foundation

public enum ProceduralWaveform {

    /// Genera peaks RGB procedurales. `columns` ≈ 2000 para overview.
    /// Devuelve tupla (low, mid, high) de [UInt8] con la misma longitud.
    public static func generate(seed: Int, duration: Double, columns: Int = 2000) -> (low: [UInt8], mid: [UInt8], high: [UInt8]) {
        guard columns > 0, duration > 0 else {
            return ([], [], [])
        }
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
        var low  = [UInt8](repeating: 0, count: columns)
        var mid  = [UInt8](repeating: 0, count: columns)
        var high = [UInt8](repeating: 0, count: columns)

        // Envelope: intro ramp + body + outro ramp
        let introEnd  = max(1, columns / 12)   // ~8%
        let outroStart = columns - max(1, columns / 10) // ~90%

        // Pre-compute a few "energy bumps" to simulate drops/builds
        let bumpCount = 3 + Int(rng.next() % 5) // 3–7 bumps
        var bumps: [(center: Int, width: Int, boost: Double)] = []
        for _ in 0..<bumpCount {
            let center = Int(rng.next() % UInt64(columns))
            let width = 40 + Int(rng.next() % 120)
            let boost = 0.15 + Double(rng.next() % 30) / 100.0
            bumps.append((center, width, boost))
        }

        for i in 0..<columns {
            // Base envelope
            var env: Double = 1.0
            if i < introEnd {
                env = Double(i) / Double(introEnd)
                env = env * env // quadratic ramp
            } else if i > outroStart {
                let f = Double(columns - 1 - i) / Double(max(1, columns - 1 - outroStart))
                env = f * f
            }

            // Random component per column
            let r1 = Double(rng.next() % 200) / 255.0
            let r2 = Double(rng.next() % 180) / 255.0
            let r3 = Double(rng.next() % 160) / 255.0

            // Base levels: low dominant (kick), mid moderate, high subtle
            var lv = 0.35 + r1 * 0.50
            var mv = 0.20 + r2 * 0.45
            var hv = 0.12 + r3 * 0.40

            // Apply bumps
            for b in bumps {
                let dist = abs(i - b.center)
                if dist < b.width {
                    let f = 1.0 - Double(dist) / Double(b.width)
                    lv += b.boost * f * 0.8
                    mv += b.boost * f * 1.0
                    hv += b.boost * f * 0.6
                }
            }

            // Smoothing: slight beat pulse every ~16 columns (simulates 4-bar patterns)
            let beatPulse = 1.0 + 0.12 * sin(Double(i) * .pi * 2.0 / 16.0)
            lv *= beatPulse

            // Apply envelope and clamp
            lv = min(1.0, max(0.05, lv * env))
            mv = min(1.0, max(0.03, mv * env))
            hv = min(1.0, max(0.02, hv * env))

            low[i]  = UInt8(lv * 255)
            mid[i]  = UInt8(mv * 255)
            high[i] = UInt8(hv * 255)
        }

        return (low, mid, high)
    }
}

// Minimal deterministic PRNG (no Foundation random needed)
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
