// TracklistStore.swift
// Setlist de concierto: carga, match fuzzy al play y override manual.

import Foundation
import Combine
import AppKit
import StageLinqKit

struct SetlistItem: Identifiable, Codable, Equatable {
    var id: UUID
    var artist: String
    var title: String
    var played: Bool
    var playedAt: Date?
    var playedBy: String
    var manual: Bool

    init(id: UUID = UUID(), artist: String = "", title: String,
         played: Bool = false, playedAt: Date? = nil,
         playedBy: String = "", manual: Bool = false) {
        self.id = id
        self.artist = artist
        self.title = title
        self.played = played
        self.playedAt = playedAt
        self.playedBy = playedBy
        self.manual = manual
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
}

@MainActor
final class TracklistStore: ObservableObject {

    @Published var items: [SetlistItem] = []
    @Published var currentID: UUID?
    @Published var pasteDraft: String = ""
    @Published var showEditor: Bool = false
    @Published var status: String = ""

    private var lastPlayKey: [String: String] = [:]

    init() {
        loadFromDisk()
    }

    var playedCount: Int { items.filter(\.played).count }

    var nextUnplayed: SetlistItem? { items.first { !$0.played } }

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
        guard let raw = try? String(contentsOf: url, encoding: .utf8)
                ?? String(contentsOf: url, encoding: .isoLatin1) else {
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

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        if currentID == id { currentID = nextUnplayed?.id }
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
        }
        persist()
    }

    // MARK: Match en vivo

    func ingest(playing: [(title: String, artist: String, source: String, isMaster: Bool)]) {
        guard !items.isEmpty else { return }
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
            if line.contains(";") || (line.contains(",") && line.split(separator: ",").count >= 2) {
                let sep: Character = line.contains(";") ? ";" : ","
                let cols = line.split(separator: sep, omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                if cols.count >= 2 {
                    let a = cols[0], b = cols[1]
                    if !a.isEmpty || !b.isEmpty {
                        out.append(SetlistItem(artist: a, title: b.isEmpty ? a : b))
                        continue
                    }
                }
            }
            if let range = line.range(of: " - ") {
                let artist = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let title = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                out.append(SetlistItem(artist: artist, title: title.isEmpty ? artist : title))
            } else if let range = line.range(of: " – ") {
                let artist = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let title = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                out.append(SetlistItem(artist: artist, title: title.isEmpty ? artist : title))
            } else {
                let names = TrackNaming.parse(fileURL: URL(fileURLWithPath: line))
                if !names.artist.isEmpty {
                    out.append(SetlistItem(artist: names.artist, title: names.title))
                } else {
                    out.append(SetlistItem(title: TrackNaming.cleanTitle(line)))
                }
            }
        }
        return out.filter { !$0.title.isEmpty || !$0.artist.isEmpty }
    }

    // MARK: Disco

    static func folderURL() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("STAGE CONNECT", isDirectory: true)
    }

    private var fileURL: URL {
        Self.folderURL().appendingPathComponent("setlist.json")
    }

    func persist() {
        let folder = Self.folderURL()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let loaded = try? dec.decode([SetlistItem].self, from: data) {
            items = loaded
            currentID = loaded.first { !$0.played }?.id ?? loaded.first?.id
        }
    }

    func exportTXT() -> String {
        items.map { item in
            let mark = item.played ? "[x]" : "[ ]"
            let time = item.timeText
            let by = item.playedBy
            var line = "\(mark) \(item.lineLabel)"
            if !time.isEmpty { line += "  \(time)" }
            if !by.isEmpty { line += "  \(by)" }
            return line
        }.joined(separator: "\n") + (items.isEmpty ? "" : "\n")
    }
}
