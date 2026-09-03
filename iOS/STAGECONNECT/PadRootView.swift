import SwiftUI
import StageLinqKit

struct PadRootView: View {
    @EnvironmentObject var manager: StageLinqManager
    @EnvironmentObject var proDJLink: ProDJLinkManager
    @EnvironmentObject var testLink: TestLinkReceiver
    @EnvironmentObject var license: LicenseStore

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if license.isUnlocked {
                monitor
            } else {
                ActivationView()
            }
        }
    }

    private var monitor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("STAGE CONNECT")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.6)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(license.statusText)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
                Button("Quitar licencia") {
                    license.deactivate()
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.red.opacity(0.85))
                .buttonStyle(.plain)
                Text("iPad")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if decks.isEmpty {
                Spacer()
                Text(manager.devices.isEmpty
                     ? "Buscando reproductores en la red local…"
                     : "conectado / esperando pista")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                Text("Mismo switch o misma red WiFi. Desactiva el aislamiento de AP.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if let master = decks.first(where: { $0.isMaster || $0.isPlaying }) ?? decks.first {
                            padCard(master, hero: true)
                            Rectangle().fill(Theme.rowDivider).frame(height: 2)
                        }
                        ForEach(decks) { d in
                            padCard(d, hero: false)
                        }
                    }
                }
            }
        }
    }

    private func padCard(_ d: PadDeck, hero: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(d.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.textTertiary)
                padSignalLED(at: d.signalAt, stamp: d.controlStamp)
                Spacer()
                Text(d.key.isEmpty ? "—" : d.key)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(d.key.isEmpty ? Theme.ledDim : Theme.purple)
                Text(LTCGenerator.timecodeText(seconds: d.elapsed ?? 0, fps: 25))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.accent)
                Text(d.bpm > 0 ? String(format: "%.2f", d.bpm) : "---.--")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.ledGreen)
            }
            Text(d.title.isEmpty ? "SIN PISTA" : d.title)
                .font(.system(size: hero ? 20 : 14, weight: .bold))
                .foregroundColor(Theme.ledGreen)
                .lineLimit(1)
            if !d.artist.isEmpty {
                Text(d.artist).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            WaveformView(
                progress: d.progress,
                trackLength: d.length,
                bpm: d.bpm,
                beatInBar: d.beatInBar,
                isPlaying: d.isPlaying,
                accent: Theme.accent,
                trackSeed: d.title.hashValue,
                peaks: d.peaks,
                peaksLow: d.peaksLow,
                peaksMid: d.peaksMid,
                peaksHigh: d.peaksHigh,
                mode: hero ? .scrolling : .overview,
                windowSeconds: 12
            )
            .frame(height: hero ? 120 : 48)
        }
        .padding(12)
        .background(Theme.deckFill)
    }

    private var decks: [PadDeck] {
        var rows: [PadDeck] = []
        let _ = manager.rosterRevision
        let _ = proDJLink.rosterRevision
        let _ = testLink.rosterTick
        if testLink.roster.denonOn {
            for i in 0..<2 {
                if let o = testLink.snapshot?.deck(i), o.loaded {
                    rows.append(PadDeck(
                        id: "denon-test-\(i)",
                        label: i == 0 ? "DENON A" : "DENON B",
                        title: TrackNaming.cleanTitle(o.title),
                        artist: o.artist,
                        key: MusicalKey.resolved(raw: o.key, title: o.title, artist: o.artist),
                        bpm: o.bpm,
                        elapsed: o.position,
                        length: o.duration,
                        progress: o.progress,
                        isPlaying: o.playing,
                        isMaster: o.isMaster,
                        beatInBar: MusicalClock.beatInBar(position: o.position, bpm: o.bpm),
                        peaks: o.peaks,
                        peaksLow: o.peaksLow,
                        peaksMid: o.peaksMid,
                        peaksHigh: o.peaksHigh,
                        signalAt: testLink.lastPacketAt,
                        controlStamp: padStamp(playing: o.playing, master: o.isMaster, title: o.title)
                    ))
                }
            }
            for device in manager.devices where !device.isDenonSimulator {
                for deck in device.decks where deck.songLoaded {
                    _ = deck.activityTick
                    rows.append(PadDeck(
                        id: "denon-\(device.id)-\(deck.id)",
                        label: "SC6000 \(deck.id)",
                        title: TrackNaming.cleanTitle(deck.trackTitle),
                        artist: deck.trackArtist,
                        key: MusicalKey.resolved(raw: deck.trackKey, title: deck.trackTitle, artist: deck.trackArtist),
                        bpm: deck.bpm,
                        elapsed: deck.beatProgress.flatMap { deck.trackLength > 0 ? $0 * deck.trackLength : nil },
                        length: deck.trackLength > 0 ? deck.trackLength : nil,
                        progress: deck.beatProgress,
                        isPlaying: deck.playState == .playing,
                        isMaster: deck.isMaster,
                        beatInBar: Int(deck.currentBeat.truncatingRemainder(dividingBy: 4)) + 1,
                        peaks: [],
                        signalAt: deck.lastPacketAt,
                        controlStamp: padStamp(
                            playing: deck.playState == .playing,
                            master: deck.isMaster,
                            title: deck.trackTitle,
                            extra: Int((deck.volume * 100).rounded()) &+ (deck.scratchTouch ? 17 : 0)
                        )
                    ))
                }
            }
        } else {
            for device in manager.devices where !device.isDenonSimulator {
                for deck in device.decks where deck.songLoaded {
                    _ = deck.activityTick
                    rows.append(PadDeck(
                        id: "denon-\(device.id)-\(deck.id)",
                        label: "SC6000 \(deck.id)",
                        title: TrackNaming.cleanTitle(deck.trackTitle),
                        artist: deck.trackArtist,
                        key: MusicalKey.resolved(raw: deck.trackKey, title: deck.trackTitle, artist: deck.trackArtist),
                        bpm: deck.bpm,
                        elapsed: deck.beatProgress.flatMap { deck.trackLength > 0 ? $0 * deck.trackLength : nil },
                        length: deck.trackLength > 0 ? deck.trackLength : nil,
                        progress: deck.beatProgress,
                        isPlaying: deck.playState == .playing,
                        isMaster: deck.isMaster,
                        beatInBar: Int(deck.currentBeat.truncatingRemainder(dividingBy: 4)) + 1,
                        peaks: [],
                        signalAt: deck.lastPacketAt,
                        controlStamp: padStamp(
                            playing: deck.playState == .playing,
                            master: deck.isMaster,
                            title: deck.trackTitle,
                            extra: Int((deck.volume * 100).rounded()) &+ (deck.scratchTouch ? 17 : 0)
                        )
                    ))
                }
            }
        }
        if testLink.roster.hasPioneerTrack, !testLink.roster.denonOn,
           let o = testLink.snapshot?.decks.first(where: { $0.loaded && $0.playing })
            ?? testLink.snapshot?.firstLoadedDeck() {
            rows.append(PadDeck(
                id: "pioneer-test",
                label: "CDJ-3000 · PLAYER 2",
                title: TrackNaming.cleanTitle(o.title),
                artist: o.artist,
                key: MusicalKey.resolved(raw: o.key, title: o.title, artist: o.artist),
                bpm: o.bpm,
                elapsed: o.position,
                length: o.duration,
                progress: o.progress,
                isPlaying: o.playing,
                isMaster: o.isMaster || o.playing,
                beatInBar: MusicalClock.beatInBar(position: o.position, bpm: o.bpm),
                peaks: o.peaks,
                peaksLow: o.peaksLow,
                peaksMid: o.peaksMid,
                peaksHigh: o.peaksHigh,
                signalAt: testLink.lastPacketAt,
                controlStamp: padStamp(playing: o.playing, master: o.isMaster, title: o.title)
            ))
        }
        for device in proDJLink.devices where device.isLANPlayerWithTrack {
            _ = device.activityTick
            rows.append(PadDeck(
                id: "pioneer-\(device.id)",
                label: "PLAYER \(device.playerNumber)",
                title: TrackNaming.cleanTitle(device.trackTitle),
                artist: device.trackArtist,
                key: MusicalKey.resolved(raw: device.trackKey, title: device.trackTitle, artist: device.trackArtist),
                bpm: device.effectiveBPM,
                elapsed: device.hasPosition ? device.playhead : nil,
                length: device.trackLength > 0 ? device.trackLength : nil,
                progress: device.hasPosition ? device.progress : nil,
                isPlaying: device.isPlaying,
                isMaster: device.isMaster,
                beatInBar: device.beatInBar,
                peaks: device.peaks,
                peaksLow: device.peaksLow,
                peaksMid: device.peaksMid,
                peaksHigh: device.peaksHigh,
                signalAt: device.lastSeen,
                controlStamp: padStamp(
                    playing: device.isPlaying,
                    master: device.isMaster,
                    title: device.trackTitle,
                    extra: device.playModeLabel.hashValue
                )
            ))
        }
        return rows
    }

    private func padStamp(playing: Bool, master: Bool, title: String, extra: Int = 0) -> Int {
        var h = (playing ? 1 : 0) &+ (master ? 3 : 0) &+ extra
        for u in title.unicodeScalars { h = h &* 31 &+ Int(u.value) }
        return h
    }

    private func padSignalLED(at signalAt: Date, stamp: Int) -> some View {
        PadSignalLED(signalAt: signalAt, stamp: stamp)
    }
}

private struct PadSignalLED: View {
    let signalAt: Date
    let stamp: Int
    @State private var flashUntil: Date = .distantPast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { timeline in
            let now = timeline.date
            let live = now.timeIntervalSince(signalAt) < 0.9
            let flash = now < flashUntil
            Capsule()
                .fill(flash ? Color.white : (live ? Theme.ledGreen : Color.white.opacity(0.14)))
                .frame(width: 8, height: 14)
                .shadow(color: flash || live ? Theme.ledGreen.opacity(0.8) : .clear, radius: 3)
        }
        .onChange(of: stamp) { _ in
            flashUntil = Date().addingTimeInterval(0.3)
        }
    }
}

private struct PadDeck: Identifiable {
    let id: String
    let label: String
    let title: String
    let artist: String
    let key: String
    let bpm: Double
    let elapsed: Double?
    let length: Double?
    let progress: Double?
    let isPlaying: Bool
    let isMaster: Bool
    let beatInBar: Int
    let peaks: [UInt8]
    var peaksLow: [UInt8] = []
    var peaksMid: [UInt8] = []
    var peaksHigh: [UInt8] = []
    var signalAt: Date = .distantPast
    var controlStamp: Int = 0
}
