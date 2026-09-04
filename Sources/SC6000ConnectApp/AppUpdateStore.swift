// AppUpdateStore.swift
// Comprueba y descarga builds Mac publicados en el servidor de licencias.

import Foundation
import AppKit
import Combine
import CryptoKit

struct AppRemoteRelease: Equatable {
    let version: String
    let url: URL
    let notes: String
    let publishedAt: String?
    let sha256: String?
    let filename: String?
    let size: Int64?
}

final class AppUpdateStore: ObservableObject {

    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var available: AppRemoteRelease?
    @Published private(set) var statusMessage: String = ""
    @Published var lastError: String = ""

    /// Misma cadena que LicenseStore (Express local → app.entikmedia.com).
    private static let serverBases = [
        "http://127.0.0.1:3000",
        "https://app.entikmedia.com",
    ]

    private var downloadTask: URLSessionDownloadTask?
    private var progressObserver: NSKeyValueObservation?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "0.0.0"
    }

    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var hasUpdate: Bool { available != nil }

    var bannerText: String {
        guard let avail = available else { return "" }
        return "v\(avail.version) disponible"
    }

    // MARK: - Check

    func checkForUpdates(completion: ((Bool) -> Void)? = nil) {
        guard !isChecking, !isDownloading else {
            completion?(available != nil)
            return
        }
        isChecking = true
        lastError = ""
        statusMessage = "Comprobando…"

        attemptLatest(bases: Self.serverBases) { [weak self] result in
            guard let self else { return }
            self.isChecking = false
            switch result {
            case .success(let remote):
                if Self.isNewer(remote.version, than: Self.currentVersion) {
                    self.available = remote
                    self.statusMessage = "Hay una version nueva: \(remote.version)"
                    completion?(true)
                } else {
                    self.available = nil
                    self.statusMessage = "Estas al dia (v\(Self.currentVersion))"
                    completion?(false)
                }
            case .notFound:
                self.available = nil
                self.statusMessage = "No hay builds publicados en el servidor"
                completion?(false)
            case .unreachable:
                self.lastError = "No se pudo contactar con el servidor de actualizaciones"
                self.statusMessage = self.lastError
                completion?(false)
            case .badResponse(let msg):
                self.lastError = msg
                self.statusMessage = msg
                completion?(false)
            }
        }
    }

    // MARK: - Download + open

    func installAvailableUpdate() {
        guard let remote = available else { return }
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        lastError = ""
        statusMessage = "Descargando \(remote.filename ?? remote.version)…"

        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: remote.url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressObserver = nil
                self.downloadTask = nil

                defer { self.isDownloading = false }

                if let error {
                    self.lastError = error.localizedDescription
                    self.statusMessage = "Error de descarga"
                    return
                }
                guard let tempURL else {
                    self.lastError = "Descarga incompleta"
                    self.statusMessage = self.lastError
                    return
                }
                let http = response as? HTTPURLResponse
                if let code = http?.statusCode, !(200...299).contains(code) {
                    self.lastError = "Servidor respondio \(code)"
                    self.statusMessage = self.lastError
                    return
                }

                do {
                    let dest = try self.saveToDownloads(from: tempURL, suggested: remote.filename, url: remote.url)
                    if let expected = remote.sha256, !expected.isEmpty {
                        let got = try Self.sha256Hex(of: dest)
                        if got.lowercased() != expected.lowercased() {
                            try? FileManager.default.removeItem(at: dest)
                            self.lastError = "Checksum SHA-256 no coincide"
                            self.statusMessage = self.lastError
                            return
                        }
                    }
                    self.statusMessage = "Descargado en Descargas. Abre el archivo e instala (sustituye la app en Aplicaciones)."
                    self.revealAndOpen(dest)
                    self.available = nil
                } catch {
                    self.lastError = error.localizedDescription
                    self.statusMessage = "No se pudo guardar el build"
                }
            }
        }
        progressObserver = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = prog.fractionCompleted
            }
        }
        downloadTask = task
        task.resume()
    }

    // MARK: - Network

    private enum LatestResult {
        case success(AppRemoteRelease)
        case notFound
        case unreachable
        case badResponse(String)
    }

    private struct APIBody: Decodable {
        let ok: Bool?
        let version: String?
        let url: String?
        let notes: String?
        let publishedAt: String?
        let sha256: String?
        let filename: String?
        let size: Int64?
        let error: String?
    }

    private func attemptLatest(bases: [String], completion: @escaping (LatestResult) -> Void) {
        guard let base = bases.first,
              let url = URL(string: base + "/api/app/update") else {
            DispatchQueue.main.async { completion(.unreachable) }
            return
        }
        let rest = Array(bases.dropFirst())

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("STAGE CONNECT/\(Self.currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = base.contains("127.0.0.1") ? 3 : 4

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let finish: (LatestResult) -> Void = { r in
                DispatchQueue.main.async { completion(r) }
            }

            let unreachable = (error != nil)
                || response == nil
                || ((response as? HTTPURLResponse)?.statusCode ?? 0) >= 500

            if unreachable {
                if !rest.isEmpty {
                    self.attemptLatest(bases: rest, completion: completion)
                } else {
                    finish(.unreachable)
                }
                return
            }

            guard let http = response as? HTTPURLResponse, let data else {
                finish(.unreachable)
                return
            }

            if http.statusCode == 404 {
                finish(.notFound)
                return
            }

            guard let body = try? JSONDecoder().decode(APIBody.self, from: data),
                  let ver = body.version, let urlStr = body.url,
                  let downloadURL = URL(string: urlStr) else {
                if !rest.isEmpty {
                    self.attemptLatest(bases: rest, completion: completion)
                } else {
                    finish(.badResponse("Respuesta de actualizacion no valida"))
                }
                return
            }

            if body.ok == false {
                finish(.badResponse(body.error ?? "Sin actualizacion"))
                return
            }

            finish(.success(AppRemoteRelease(
                version: ver,
                url: downloadURL,
                notes: body.notes ?? "",
                publishedAt: body.publishedAt,
                sha256: body.sha256,
                filename: body.filename,
                size: body.size
            )))
        }.resume()
    }

    // MARK: - Files

    private func saveToDownloads(from temp: URL, suggested: String?, url: URL) throws -> URL {
        let name = (suggested?.isEmpty == false ? suggested! : url.lastPathComponent)
            .replacingOccurrences(of: "/", with: "_")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            let base = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            dest = downloads.appendingPathComponent("\(base)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        }
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    private func revealAndOpen(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
        let ext = file.pathExtension.lowercased()
        if ext == "dmg" || ext == "pkg" {
            NSWorkspace.shared.open(file)
        }
        let alert = NSAlert()
        alert.messageText = "Actualizacion descargada"
        alert.informativeText = """
        Archivo en Descargas:
        \(file.lastPathComponent)

        1. Abre el .dmg / descomprime el .zip
        2. Arrastra STAGE CONNECT a Aplicaciones (sustituye la anterior)
        3. Vuelve a abrir la app

        La app actual puede seguir abierta hasta que cierres e instales.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Entendido")
        alert.runModal()
    }

    private static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Comparacion semver simple (mayor = update).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = parseVersion(remote)
        let l = parseVersion(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func parseVersion(_ raw: String) -> [Int] {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let core = cleaned.split(separator: "-", maxSplits: 1).first
            ?? cleaned.split(separator: "+", maxSplits: 1).first
            ?? Substring(cleaned)
        return core.split(separator: ".").map { part in
            Int(part.filter { $0.isNumber }) ?? 0
        }
    }
}
