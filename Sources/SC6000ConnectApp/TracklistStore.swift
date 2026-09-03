// TracklistStore.swift
// Setlist de concierto: TC/playhead, anotaciones FX, match fuzzy y override manual.

import Foundation
import Combine
import AppKit
import StageLinqKit

struct TrackAnnotation: Identifiable, Codable, Equatable {
    var id: UUID
    /// Segundos absolutos en la línea de tiempo del show (mismo reloj que el TC).
    var tcSeconds: Double
    var text: String

    init(id: UUID = UUID(), tcSeconds: Double = 0, text: String = "") {
        self.id = id
        self.tcSeconds = max(0, tcSeconds)
        self.text = text
    }

    var smpte: String {
        TracklistSMPTE.format(seconds: tcSeconds)
    }
}

struct SetlistItem: Identifiable, Codable, Equatable {
    var id: UUID
    var artist: String
    var title: String
    var played: Bool
    var playedAt: Date?
    var playedBy: String
    var manual: Bool
    /// Inicio de esta pista en el TC del show (nil = solo match por título / orden).
    var tcSeconds: Double?
    /// Nota libre de pista (FX globales del tema, etc.).
    var notes: String
    /// Cues / anotaciones ligadas a un punto de TC dentro del tramo.
    var annotations: [TrackAnnotation]

    init(id: UUID = UUID(), artist: String = "", title: String,
         played: Bool = false, playedAt: Date? = nil,
         playedBy: String = "", manual: Bool = false,
         tcSeconds: Double? = nil, notes: String = "",
         annotations: [TrackAnnotation] = []) {
        self.id = id
        self.artist = artist
        self.title = title
        self.played = played
        self.playedAt = playedAt
        self.playedBy = playedBy
        self.manual = manual
        self.tcSeconds = tcSeconds.map { max(0, $0) }
        self.notes = notes
        self.annotations = annotations
    }

    var displayTitle: String {
        title.isEmpty ? "—" : title
    }

    var displayArtist: String { artist }

    var lineLabel: String {
        if artist.isEmpty { return title }
        if title.isEmpty { return artist }
        return "\(artist) - \(title)"
    }

    var timeText: String {
        guard let playedAt else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: playedAt)
    }

    var tcSMPTE: String {
        guard let tcSeconds else { return "" }
        return TracklistSMPTE.format(seconds: tcSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case id, artist, title, played, playedAt, playedBy, manual
        case tcSeconds, notes, annotations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        played = try c.decodeIfPresent(Bool.self, forKey: .played) ?? false
        playedAt = try c.decodeIfPresent(Date.self, forKey: .playedAt)
        playedBy = try c.decodeIfPresent(String.self, forKey: .playedBy) ?? ""
        manual = try c.decodeIfPresent(Bool.self, forKey: .manual) ?? false
        tcSeconds = try c.decodeIfPresent(Double.self, forKey: .tcSeconds)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        annotations = try c.decodeIfPresent([TrackAnnotation].self, forKey: .annotations) ?? []
    }
}

@MainActor
final class TracklistStore: ObservableObject {

    @Published var items: [SetlistItem] = []
    @Published var currentID: UUID?
    @Published var pasteDraft: String = ""
    @Published var showEditor: Bool = false
    @Published var status: String = ""
    /// Playhead / TC del show en segundos (misma referencia que los tcSeconds de las filas).
    @Published var playheadSeconds: Double = 0
    @Published var playheadSMPTE: String = "00:00:00:00"
    @Published var fps: Double = 25

    /// Snapshot para el bridge web (lectura desde tick no aislado).
    nonisolated(unsafe) private(set) var cachedBridgePayload: [String: Any] = [:]

    private var lastPlayKey: [String: String] = [:]
    private var persistWork: DispatchWorkItem?

    init() {
        loadFromDisk()
    }

    var playedCount: Int { items.filter(\.played).count }

    var nextUnplayed: SetlistItem? { items.first { !$0.played } }

    var currentItem: SetlistItem? {
        guard let currentID else { return nil }
        return items.first { $0.id == currentID }
    }

    /// Anotaciones visibles ahora: nota de pista activa + cues cuyo TC ≤ playhead
    /// hasta el siguiente cue (o fin del tramo).
    var liveAnnotations: [TrackAnnotation] {
        guard let item = currentItem else { return [] }
        let sorted = item.annotations.sorted { $0.tcSeconds < $1.tcSeconds }
        guard !sorted.isEmpty else { return [] }
        var visible: [TrackAnnotation] = []
        for (i, ann) in sorted.enumerated() {
            let end: Double = {
                if i + 1 < sorted.count { return sorted[i + 1].tcSeconds }
                if let next = nextTrackTC(after: item) { return next }
                return playheadSeconds + 3600
            }()
            if playheadSeconds + 0.001 >= ann.tcSeconds && playheadSeconds < end {
                visible.append(ann)
            }
        }
        return visible
    }

    var liveNotes: String {
        currentItem?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func item(id: UUID) -> SetlistItem? { items.first { $0.id == id } }

    // MARK: Carga

    func replace(fromLines text: String) {
        let parsed = Self.parseLines(text)
        items = parsed
        currentID = parsed.first { !$0.played }?.id
        lastPlayKey.removeAll()
        persist()
        status = parsed.isEmpty ? "Lista vacía" : "\(parsed.count) pistas cargadas"
    }

    func append(fromLines text: String) {
        let parsed = Self.parseLines(text)
        items.append(contentsOf: parsed)
        persist()
        status = "+\(parsed.count) · \(items.count) en total"
    }

    func importFromHistory(_ history: [PlaylistEntry]) {
        var seen = Set<String>()
        var out: [SetlistItem] = []
        for entry in history.reversed() {
            let title = TrackNaming.cleanTitle(entry.title)
            guard !title.isEmpty else { continue }
            let key = Self.normalize(entry.artist) + "|" + Self.normalize(title)
            guard seen.insert(key).inserted else { continue }
            out.append(SetlistItem(artist: entry.artist, title: title))
        }
        items = out
        currentID = out.first?.id
        lastPlayKey.removeAll()
        persist()
        status = out.isEmpty ? "El historial no tiene títulos" : "\(out.count) desde historial"
    }

    func importFile(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let raw: String?
        if let u = try? String(contentsOf: url, encoding: .utf8) {
            raw = u
        } else {
            raw = try? String(contentsOf: url, encoding: .isoLatin1)
        }
        guard let raw else {
            status = "No se pudo leer el archivo"
            return
        }
        replace(fromLines: raw)
    }

    func clearMarks() {
        for i in items.indices {
            items[i].played = false
            items[i].playedAt = nil
            items[i].playedBy = ""
            items[i].manual = false
        }
        currentID = items.first?.id
        lastPlayKey.removeAll()
        persist()
        status = "Marcas borradas"
    }

    func clearAll() {
        items.removeAll()
        currentID = nil
        lastPlayKey.removeAll()
        persist()
        status = "Lista vacía"
    }

    func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func moveUp(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i > 0 else { return }
        items.swapAt(i, i - 1)
        persist()
    }

    func moveDown(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i + 1 < items.count else { return }
        items.swapAt(i, i + 1)
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        if currentID == id { currentID = nextUnplayed?.id }
        persist()
    }

    func addBlankRow() {
        let item = SetlistItem(title: "Nueva pista")
        items.append(item)
        currentID = item.id
        persist()
        status = "Fila añadida"
    }

    func updateTitle(_ id: UUID, title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        persistDebounced()
    }

    func updateArtist(_ id: UUID, artist: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].artist = artist
        persistDebounced()
    }

    func updateNotes(_ id: UUID, notes: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].notes = notes
        persistDebounced()
    }

    /// Enlaza la fila al TC actual o a un SMPTE escrito (HH:MM:SS:FF o HH:MM:SS).
    func setTC(_ id: UUID, smpte: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = smpte.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            items[i].tcSeconds = nil
        } else if let sec = TracklistSMPTE.parse(trimmed, fps: fps) {
            items[i].tcSeconds = sec
        } else {
            status = "TC inválido (usa HH:MM:SS:FF)"
            return
        }
        persist()
        syncToPlayhead(seconds: playheadSeconds, smpte: playheadSMPTE, fps: fps)
        status = "TC enlazado"
    }

    func captureTC(_ id: UUID) {
        setTC(id, smpte: playheadSMPTE)
    }

    func addAnnotation(to trackID: UUID, text: String = "FX", atSeconds: Double? = nil) {
        guard let i = items.firstIndex(where: { $0.id == trackID }) else { return }
        let sec = atSeconds ?? playheadSeconds
        items[i].annotations.append(TrackAnnotation(tcSeconds: sec, text: text))
        items[i].annotations.sort { $0.tcSeconds < $1.tcSeconds }
        persist()
    }

    func updateAnnotation(trackID: UUID, annotationID: UUID, text: String? = nil, smpte: String? = nil) {
        guard let i = items.firstIndex(where: { $0.id == trackID }) else { return }
        guard let j = items[i].annotations.firstIndex(where: { $0.id == annotationID }) else { return }
        if let text { items[i].annotations[j].text = text }
        if let smpte {
            let trimmed = smpte.trimmingCharacters(in: .whitespacesAndNewlines)
            if let sec = TracklistSMPTE.parse(trimmed, fps: fps) {
                items[i].annotations[j].tcSeconds = sec
            }
        }
        items[i].annotations.sort { $0.tcSeconds < $1.tcSeconds }
        persistDebounced()
    }

    func removeAnnotation(trackID: UUID, annotationID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == trackID }) else { return }
        items[i].annotations.removeAll { $0.id == annotationID }
        persist()
    }

    func togglePlayed(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].played {
            items[i].played = false
            items[i].playedAt = nil
            items[i].playedBy = ""
            items[i].manual = true
        } else {
            items[i].played = true
            items[i].playedAt = Date()
            items[i].playedBy = "manual"
            items[i].manual = true
            currentID = id
        }
        persist()
    }

    func select(_ id: UUID) {
        currentID = id
    }

    // MARK: Sync TC / playhead

    /// Actualiza la pista activa según el TC del show. Si hay filas con tcSeconds,
    /// gana la última cuyo inicio ≤ playhead. Si no hay TC enlazado, no mueve current.
    func syncToPlayhead(seconds: Double, smpte: String, fps: Double) {
        self.fps = fps > 0 ? fps : 25
        playheadSeconds = max(0, seconds)
        playheadSMPTE = smpte.isEmpty
            ? TracklistSMPTE.format(seconds: playheadSeconds, fps: self.fps)
            : smpte

        let timed = items.enumerated().compactMap { idx, item -> (Int, Double)? in
            guard let t = item.tcSeconds else { return nil }
            return (idx, t)
        }.sorted { $0.1 < $1.1 }

        if !timed.isEmpty {
            var active: Int?
            for (idx, t) in timed where t <= playheadSeconds + 0.02 {
                active = idx
            }
            if let active {
                let id = items[active].id
                if currentID != id { currentID = id }
                if !items[active].played {
                    items[active].played = true
                    items[active].playedAt = items[active].playedAt ?? Date()
                    items[active].playedBy = "TC"
                    items[active].manual = false
                    persistDebounced()
                }
            }
        }
        refreshBridgeCache()
    }

    // MARK: Match en vivo (fallback sin TC)

    func ingest(playing: [(title: String, artist: String, source: String, isMaster: Bool)]) {
        guard !items.isEmpty else { return }
        let hasTC = items.contains { $0.tcSeconds != nil }
        if hasTC { return } // el TC manda cuando hay enlaces
        var highlighted: UUID?
        for deck in playing {
            let title = TrackNaming.cleanTitle(deck.title)
            guard !title.isEmpty else { continue }
            let playKey = title + "|" + deck.artist
            let isNew = lastPlayKey[deck.source] != playKey
            lastPlayKey[deck.source] = playKey
            if let match = bestMatch(title: title, artist: deck.artist) {
                if isNew, !items[match].played {
                    items[match].played = true
                    items[match].playedAt = Date()
                    items[match].playedBy = deck.isMaster ? "MASTER · \(deck.source)" : deck.source
                    items[match].manual = false
                    persist()
                }
                if highlighted == nil { highlighted = items[match].id }
            }
        }
        if let highlighted {
            currentID = highlighted
        } else if currentID == nil {
            currentID = nextUnplayed?.id
        }
    }

    /// Payload seguro para el bridge web (sin secretos).
    func publicPayload() -> [String: Any] {
        let active = currentID?.uuidString
        return [
            "tc": playheadSMPTE,
            "tcSeconds": playheadSeconds,
            "currentId": active as Any,
            "notes": liveNotes,
            "annotations": liveAnnotations.map { [
                "id": $0.id.uuidString,
                "tc": $0.smpte,
                "tcSeconds": $0.tcSeconds,
                "text": $0.text
            ] as [String: Any] },
            "items": items.map { item -> [String: Any] in
                var d: [String: Any] = [
                    "id": item.id.uuidString,
                    "title": item.title,
                    "artist": item.artist,
                    "played": item.played,
                    "notes": item.notes,
                    "active": item.id == currentID,
                ]
                if let tc = item.tcSeconds {
                    d["tcSeconds"] = tc
                    d["tc"] = TracklistSMPTE.format(seconds: tc, fps: fps)
                }
                if !item.annotations.isEmpty {
                    d["annotations"] = item.annotations.map { [
                        "id": $0.id.uuidString,
                        "tc": $0.smpte,
                        "tcSeconds": $0.tcSeconds,
                        "text": $0.text
                    ] as [String: Any] }
                }
                return d
            }
        ]
    }

    private func refreshBridgeCache() {
        cachedBridgePayload = publicPayload()
    }

    private func nextTrackTC(after item: SetlistItem) -> Double? {
        guard let start = item.tcSeconds else { return nil }
        return items.compactMap(\.tcSeconds).filter { $0 > start }.min()
    }

    private func bestMatch(title: String, artist: String) -> Int? {
        var bestIdx: Int?
        var bestScore = 0
        for (i, item) in items.enumerated() {
            let score = Self.score(item: item, title: title, artist: artist)
            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }
        return bestScore >= 72 ? bestIdx : nil
    }

    static func score(item: SetlistItem, title: String, artist: String) -> Int {
        let it = normalize(item.title)
        let ia = normalize(item.artist)
        let tt = normalize(title)
        let ta = normalize(artist)
        guard !it.isEmpty, !tt.isEmpty else { return 0 }
        if it == tt {
            if ia.isEmpty || ta.isEmpty { return 92 }
            if ia == ta { return 100 }
            if ta.contains(ia) || ia.contains(ta) { return 94 }
            return 80
        }
        if tt.contains(it) || it.contains(tt) {
            let artistHit = !ia.isEmpty && (ta.contains(ia) || ia.contains(ta))
            return artistHit ? 86 : 74
        }
        let itok = Set(it.split(separator: " ").map(String.init).filter { $0.count > 1 })
        let ttok = Set(tt.split(separator: " ").map(String.init).filter { $0.count > 1 })
        guard !itok.isEmpty, !ttok.isEmpty else { return 0 }
        let inter = itok.intersection(ttok).count
        let union = itok.union(ttok).count
        let overlap = union > 0 ? Double(inter) / Double(union) : 0
        if overlap >= 0.72 { return 76 }
        if overlap >= 0.55 && inter >= 2 { return 72 }
        return 0
    }

    static func normalize(_ raw: String) -> String {
        var t = raw.lowercased()
        t = t.replacingOccurrences(
            of: #"[\(\[]\s*(feat\.?|ft\.?|featuring)[^\)\]]*[\)\]]"#,
            with: " ", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"\b(feat\.?|ft\.?|featuring)\b.*"#,
            with: " ", options: .regularExpression)
        for word in ["radio edit", "extended mix", "club mix", "original mix",
                     "remix", "bootleg", "edit", "version", "mix"] {
            t = t.replacingOccurrences(of: word, with: " ")
        }
        let kept = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        t = String(kept)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseLines(_ text: String) -> [SetlistItem] {
        var out: [SetlistItem] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("artista") && line.lowercased().contains("titulo") { continue }

            // Prefijo TC opcional: 01:02:03:00 | Artista - Título
            var tc: Double?
            if let bar = line.firstIndex(of: "|") {
                let left = String(line[..<bar]).trimmingCharacters(in: .whitespaces)
                if let sec = TracklistSMPTE.parse(left, fps: 25) {
                    tc = sec
                    line = String(line[line.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
                }
            }

            if line.contains(";") || (line.contains(",") && line.split(separator: ",").count >= 2) {
                let sep: Character = line.contains(";") ? ";" : ","
                let cols = line.split(separator: sep, omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                if cols.count >= 2 {
                    let a = cols[0], b = cols[1]
                    if !a.isEmpty || !b.isEmpty {
                        out.append(SetlistItem(artist: a, title: b.isEmpty ? a : b, tcSeconds: tc))
                        continue
                    }
                }
            }
            if let range = line.range(of: " - ") {
                let artist = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let title = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                out.append(SetlistItem(artist: artist, title: title.isEmpty ? artist : title, tcSeconds: tc))
            } else if let range = line.range(of: " – ") {
                let artist = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let title = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                out.append(SetlistItem(artist: artist, title: title.isEmpty ? artist : title, tcSeconds: tc))
            } else {
                let names = TrackNaming.parse(fileURL: URL(fileURLWithPath: line))
                if !names.artist.isEmpty {
                    out.append(SetlistItem(artist: names.artist, title: names.title, tcSeconds: tc))
                } else {
                    out.append(SetlistItem(title: TrackNaming.cleanTitle(line), tcSeconds: tc))
                }
            }
        }
        return out.filter { !$0.title.isEmpty || !$0.artist.isEmpty }
    }

    // MARK: Disco (App Support + migración Music)

    static func appSupportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("STAGE CONNECT", isDirectory: true)
    }

    static func legacyFolderURL() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("STAGE CONNECT", isDirectory: true)
    }

    private var fileURL: URL {
        Self.appSupportURL().appendingPathComponent("tracklist.json")
    }

    private var legacyFileURL: URL {
        Self.legacyFolderURL().appendingPathComponent("setlist.json")
    }

    func persist() {
        persistWork?.cancel()
        let folder = Self.appSupportURL()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "sc.tracklist.savedAt")
        }
        refreshBridgeCache()
    }

    private func persistDebounced() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persist() }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func loadFromDisk() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? dec.decode([SetlistItem].self, from: data) {
            items = loaded
            currentID = loaded.first { !$0.played }?.id ?? loaded.first?.id
            refreshBridgeCache()
            return
        }
        if let data = try? Data(contentsOf: legacyFileURL),
           let loaded = try? dec.decode([SetlistItem].self, from: data) {
            items = loaded
            currentID = loaded.first { !$0.played }?.id ?? loaded.first?.id
            persist()
        } else {
            refreshBridgeCache()
        }
    }

    func exportTXT() -> String {
        items.map { item in
            let mark = item.played ? "[x]" : "[ ]"
            let tc = item.tcSMPTE
            var line = "\(mark)"
            if !tc.isEmpty { line += " \(tc)" }
            line += " \(item.lineLabel)"
            if !item.notes.isEmpty { line += "  · \(item.notes)" }
            if item.played {
                let time = item.timeText
                let by = item.playedBy
                if !time.isEmpty { line += "  \(time)" }
                if !by.isEmpty { line += "  \(by)" }
            }
            return line
        }.joined(separator: "\n") + (items.isEmpty ? "" : "\n")
    }
}

enum TracklistSMPTE {
    static func format(seconds: Double, fps: Double = 25) -> String {
        LTCGenerator.timecodeText(seconds: seconds, fps: fps)
    }

    static func parse(_ raw: String, fps: Double) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: ";", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: ":").map { String($0) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) else { return nil }
        let f = parts.count == 4 ? (Int(parts[3]) ?? 0) : 0
        guard h >= 0, m >= 0, m < 60, s >= 0, s < 60, f >= 0 else { return nil }
        let rate = fps > 0 ? fps : 25
        return Double(h * 3600 + m * 60 + s) + Double(f) / rate
    }
}
