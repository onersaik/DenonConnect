// ArtworkFetcher.swift
// Portada: primero el archivo (TEST / AVAsset), luego iTunes Search (sin clave).
// iTunes solo con título y artista. Timeout corto. Cache en memoria.

import Foundation
import AppKit
import Combine
import StageLinqKit

/// NSImage listo para SwiftUI. Sin CGImage no se reserva hueco.
enum ArtworkPixels {
    static func displayable(_ image: NSImage?) -> NSImage? {
        guard let image, let cg = cgImage(image), cg.width > 2, cg.height > 2 else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
           cg.width > 2, cg.height > 2 {
            return cg
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage,
              cg.width > 2, cg.height > 2 else { return nil }
        return cg
    }
}

@MainActor
final class ArtworkFetcher: ObservableObject {

    @Published private(set) var cache: [String: NSImage] = [:]
    @Published private(set) var fetching: Set<String> = []
    private var failed: Set<String> = []

    func seed(artist: String, title: String, image: NSImage) {
        guard let image = ArtworkPixels.displayable(image) else { return }
        let key = cacheKey(artist: artist, title: title)
        cache[key] = image
        failed.remove(key)
        evictIfNeeded()
    }

    /// iTunes Search solo con título Y artista. Sin ambos no pide ni deja hueco.
    func fetch(artist: String, title: String) {
        let a = TrackNaming.cleanTitle(artist)
        let t = TrackNaming.cleanTitle(title)
        guard a.count >= 2, t.count >= 2 else { return }
        let banned = ["sin titulo", "sin título", "sin pista", "unknown"]
        guard !banned.contains(t.lowercased()) else { return }
        let key = cacheKey(artist: a, title: t)
        guard cache[key] == nil, !fetching.contains(key), !failed.contains(key) else { return }
        fetching.insert(key)
        Task {
            let img = await Self.search(artist: a, title: t)
            if let img {
                cache[key] = img
                self.evictIfNeeded()
            } else {
                failed.insert(key)
            }
            fetching.remove(key)
        }
    }

    func artwork(artist: String, title: String) -> NSImage? {
        cache[cacheKey(artist: TrackNaming.cleanTitle(artist), title: TrackNaming.cleanTitle(title))]
    }

    func isFetching(artist: String, title: String) -> Bool {
        fetching.contains(cacheKey(artist: TrackNaming.cleanTitle(artist), title: TrackNaming.cleanTitle(title)))
    }

    func clear() {
        cache.removeAll()
        fetching.removeAll()
        failed.removeAll()
    }

    private static func search(artist: String, title: String) async -> NSImage? {
        let q = "\(artist) \(title)"
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(enc)&media=music&limit=1&entity=song")
        else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 10
        let session = URLSession(configuration: cfg)
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let res = (json["results"] as? [[String: Any]])?.first,
                  var au = res["artworkUrl100"] as? String else { return nil }
            au = au.replacingOccurrences(of: "100x100bb", with: "300x300bb")
            guard let iu = URL(string: au) else { return nil }
            let (id, _) = try await session.data(from: iu)
            return ArtworkPixels.displayable(NSImage(data: id))
        } catch {
            return nil
        }
    }

    private func evictIfNeeded() {
        guard cache.count > 32 else { return }
        let extra = cache.count - 24
        for key in cache.keys.prefix(extra) {
            cache.removeValue(forKey: key)
        }
    }

    private func cacheKey(artist: String, title: String) -> String {
        "\(artist.lowercased())|\(title.lowercased())"
    }
}
