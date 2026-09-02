// ArtworkFetcher.swift
// Obtiene la portada del album usando la iTunes Search API (gratuita, sin clave).
// Mantiene una cache en memoria para no repetir peticiones.

import Foundation
import AppKit
import Combine

@MainActor
final class ArtworkFetcher: ObservableObject {

    @Published private(set) var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func fetch(artist: String, title: String) {
        guard !artist.isEmpty || !title.isEmpty else { return }
        let key = cacheKey(artist: artist, title: title)
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            let img = await Self.search(artist: artist, title: title)
            if let img { cache[key] = img }
            inFlight.remove(key)
        }
    }

    func artwork(artist: String, title: String) -> NSImage? {
        cache[cacheKey(artist: artist, title: title)]
    }

    func clear() { cache.removeAll() }

    private static func search(artist: String, title: String) async -> NSImage? {
        let q = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(enc)&media=music&limit=1&entity=song")
        else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let res = (json["results"] as? [[String: Any]])?.first,
                  var au = res["artworkUrl100"] as? String else { return nil }
            au = au.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let iu = URL(string: au) else { return nil }
            let (id, _) = try await URLSession.shared.data(from: iu)
            return NSImage(data: id)
        } catch { return nil }
    }

    private func cacheKey(artist: String, title: String) -> String {
        "\(artist.lowercased())|\(title.lowercased())"
    }
}
