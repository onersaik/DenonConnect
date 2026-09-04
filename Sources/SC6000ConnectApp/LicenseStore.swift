// LicenseStore.swift
// Activacion contra el servidor de licencias, con funcionamiento offline
// una vez activada. Un directo nunca depende de que haya red.
//
// Codigo de emergencia: KEEPTHEFAITH desbloquea todo sin servidor.

import Foundation
import Combine
import IOKit

enum LicenseKind: String, Codable {
    case monthly
    case lifetime
    case trial
    case master      // desbloqueo de emergencia
}

final class LicenseStore: ObservableObject {

    // ── Estado publicado ────────────────────────────────────────────────────
    @Published private(set) var isUnlocked = false
    @Published private(set) var kind: LicenseKind?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var isChecking = false
    @Published var lastError: String = ""

    // ── Configuracion ───────────────────────────────────────────────────────
    // Prod = app.entikmedia.com (gestor de licencias detrás del túnel).
    // Orden: Express local (cabina) → app.entikmedia.com.
    // Nunca embeber trycloudflare: hostname efímero.
    // attemptServer: NXDOMAIN / 5xx / unknown / invalid (no-local) → siguiente base.
    private static let serverBases = [
        "http://127.0.0.1:3000",
        "https://app.entikmedia.com",
    ]
    private static let masterCode = "KEEPTHEFAITH"
    /// Claves de cabina (instalador). Offline, sin servidor. No son un bypass nuevo.
    private static let monthlyCode = "entikmedia"
    private static let lifetimeCode = "laif"
    private static let monthSeconds: TimeInterval = 30 * 24 * 60 * 60
    private static let appVersion = "2.0.0"

    private let defaults = UserDefaults.standard
    private let kKind    = "stageconnect.license.kind"
    private let kCode    = "stageconnect.license.code"
    private let kSince   = "stageconnect.license.activatedAt"
    private let kExpires = "stageconnect.license.expiresAt"

    init() {
        refresh()
    }

    // ── Identificador del equipo ────────────────────────────────────────────
    /// UUID del hardware. Estable entre reinicios y reinstalaciones del sistema.
    private static var deviceID: String = {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { if service != 0 { IOObjectRelease(service) } }

        guard service != 0,
              let cf = IORegistryEntryCreateCFProperty(
                  service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? String
        else {
            // Reserva: identificador propio guardado en preferencias
            let key = "stageconnect.deviceFallbackID"
            if let saved = UserDefaults.standard.string(forKey: key) { return saved }
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: key)
            return fresh
        }
        return cf
    }()

    private static var deviceLabel: String {
        Host.current().localizedName ?? "Mac"
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // ── Lectura del estado guardado ─────────────────────────────────────────
    func refresh() {
        lastError = ""

        guard let raw = defaults.string(forKey: kKind),
              let stored = LicenseKind(rawValue: raw) else {
            clearState()
            return
        }

        kind = stored

        // Emergencia y vitalicia: no caducan, no piden red.
        if stored == .master || stored == .lifetime {
            expiresAt = nil
            isUnlocked = true
            return
        }

        let end = storedExpiry()
        expiresAt = end
        if let end, Date() >= end {
            // Cabina: una licencia ya validada no se borra ni se apaga
            // porque el mes acabó y app.entikmedia.com no responde.
            isUnlocked = true
            lastError = "Licencia caducada. Sigue en cabina local. Renueva cuando haya red."
            return
        }
        isUnlocked = true
    }

    private func storedExpiry() -> Date? {
        let exp = defaults.double(forKey: kExpires)
        if exp > 0 { return Date(timeIntervalSince1970: exp) }
        let since = defaults.double(forKey: kSince)
        if since > 0 {
            return Date(timeIntervalSince1970: since).addingTimeInterval(Self.monthSeconds)
        }
        return nil
    }

    // ── Activacion ──────────────────────────────────────────────────────────

    /// Activa con el codigo dado. Llama a `completion` en el hilo principal.
    func activate(code rawCode: String, completion: @escaping (Bool) -> Void) {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = code.uppercased().replacingOccurrences(of: " ", with: "")
        let lower = code.lowercased()
        lastError = ""

        guard !code.isEmpty else {
            lastError = "Introduce un codigo."
            completion(false)
            return
        }

        // 1. Cabina: emergencia y claves de instalador. Sin red.
        if compact == Self.masterCode {
            persist(kind: .master, code: Self.masterCode, expires: nil)
            completion(true)
            return
        }
        if lower == Self.lifetimeCode {
            persist(kind: .lifetime, code: Self.lifetimeCode, expires: nil)
            completion(true)
            return
        }
        if lower == Self.monthlyCode {
            persist(kind: .monthly, code: Self.monthlyCode,
                    expires: Date().addingTimeInterval(Self.monthSeconds))
            completion(true)
            return
        }

        // 2. Clave SCL/SCM/SCT: servidor. Si está caído, NO se bloquea
        // una licencia ya guardada; esta llamada solo falla el canje nuevo.
        isChecking = true
        verifyWithServer(path: "/api/activate", code: code) { [weak self] result in
            guard let self else { return }
            self.isChecking = false

            switch result {
            case .success(let info):
                let k = LicenseKind(rawValue: info.kind) ?? .lifetime
                let exp = info.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                self.persist(kind: k, code: code, expires: exp)
                completion(true)

            case .rejected(_, let mensaje):
                self.lastError = mensaje
                completion(false)

            case .unreachable:
                self.lastError = "Sin servidor de licencias. Usa la clave de cabina del instalador o el desbloqueo de emergencia. El descubrimiento LAN no se apaga."
                completion(false)
            }
        }
    }

    /// Version sincrona por compatibilidad con el codigo existente.
    @discardableResult
    func activate(code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.uppercased().replacingOccurrences(of: " ", with: "")
        let lower = trimmed.lowercased()
        if compact == Self.masterCode {
            persist(kind: .master, code: Self.masterCode, expires: nil)
            return true
        }
        if lower == Self.lifetimeCode {
            persist(kind: .lifetime, code: Self.lifetimeCode, expires: nil)
            return true
        }
        if lower == Self.monthlyCode {
            persist(kind: .monthly, code: Self.monthlyCode,
                    expires: Date().addingTimeInterval(Self.monthSeconds))
            return true
        }
        activate(code: code) { _ in }
        return false   // SCL: el resultado llega por @Published
    }

    // ── Comprobacion en segundo plano ───────────────────────────────────────

    /// Latido opcional. Si el servidor dice que la licencia esta revocada,
    /// se desactiva. Cualquier otro fallo (sin red, servidor caido) se ignora:
    /// la aplicacion sigue funcionando.
    func verifyInBackground() {
        guard isUnlocked, kind != .master,
              let code = defaults.string(forKey: kCode) else { return }

        // Claves de instalador / cabina: no viven en el servidor. Un /api/verify
        // "unknown" no debe tumbar el directo cuando app.entikmedia.com vuelva online.
        let lower = code.lowercased()
        if lower == Self.monthlyCode || lower == Self.lifetimeCode { return }

        verifyWithServer(path: "/api/verify", code: code) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                if let exp = info.expiresAt {
                    self.defaults.set(TimeInterval(exp), forKey: self.kExpires)
                    self.expiresAt = Date(timeIntervalSince1970: TimeInterval(exp))
                }
            case .rejected(let status, let mensaje):
                self.lastError = mensaje
                // Caducada: cabina local sigue (igual que refresh()). Solo
                // revocación / equipo no autorizado apagan la licencia.
                if status == "expired" { return }
                if status == "revoked" || status == "device_unknown" || status == "device_limit" {
                    self.deactivate()
                }
            case .unreachable:
                break   // sin red: no se toca nada
            }
        }
    }

    // ── Desactivar ──────────────────────────────────────────────────────────

    func deactivate() {
        // Avisa al servidor para liberar el equipo, sin esperar respuesta
        if kind != .master, let code = defaults.string(forKey: kCode) {
            verifyWithServer(path: "/api/release", code: code) { _ in }
        }
        clearStored()
        clearState()
    }

    // ── Texto de estado ─────────────────────────────────────────────────────

    var statusText: String {
        switch kind {
        case .master:
            return "Desbloqueo de emergencia activo"
        case .lifetime:
            return "Licencia vitalicia"
        case .trial:
            if let end = expiresAt, Date() >= end {
                return "Prueba caducada · cabina local"
            }
            if let end = expiresAt { return "Prueba · caduca \(Self.fmt.string(from: end))" }
            return "Version de prueba"
        case .monthly:
            if let end = expiresAt, Date() >= end {
                return "Caducada · cabina local (renueva con red)"
            }
            if let end = expiresAt { return "Suscripcion · renueva \(Self.fmt.string(from: end))" }
            return "Suscripcion mensual"
        case nil:
            return "Sin licencia"
        }
    }

    var daysRemaining: Int? {
        guard let end = expiresAt else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0)
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // ── Red ─────────────────────────────────────────────────────────────────

    private struct ServerLicense: Decodable {
        let kind: String
        let status: String
        let expiresAt: Int?
        let maxDevices: Int?
    }

    private struct ServerResponse: Decodable {
        let ok: Bool
        let status: String?
        let error: String?
        let license: ServerLicense?
    }

    private enum VerifyResult {
        case success(ServerLicense)
        case rejected(status: String?, message: String)
        case unreachable
    }

    private func verifyWithServer(path: String,
                                  code: String,
                                  completion: @escaping (VerifyResult) -> Void) {
        attemptServer(bases: Self.serverBases, path: path, code: code, completion: completion)
    }

    private func attemptServer(bases: [String],
                               path: String,
                               code: String,
                               completion: @escaping (VerifyResult) -> Void) {
        guard let base = bases.first,
              let url = URL(string: base + path) else {
            DispatchQueue.main.async { completion(.unreachable) }
            return
        }
        let rest = Array(bases.dropFirst())

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("STAGE CONNECT/\(Self.appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        // app.entikmedia.com lento/caído: fallback rápido a Express local (:3000).
        req.timeoutInterval = base.contains("127.0.0.1") ? 3 : 2

        let cuerpo: [String: Any] = [
            "code":        code,
            "deviceId":    Self.deviceID,
            "deviceLabel": Self.deviceLabel,
            "osVersion":   Self.osVersion,
            "appVersion":  Self.appVersion,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: cuerpo)

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let entrega: (VerifyResult) -> Void = { r in
                DispatchQueue.main.async { completion(r) }
            }

            let unreachable = (error != nil)
                || response == nil
                || ((response as? HTTPURLResponse)?.statusCode ?? 0) >= 500

            if unreachable {
                if !rest.isEmpty {
                    self.attemptServer(bases: rest, path: path, code: code, completion: completion)
                } else {
                    entrega(.unreachable)
                }
                return
            }

            guard let http = response as? HTTPURLResponse, let data else {
                entrega(.unreachable)
                return
            }
            _ = http

            guard let res = try? JSONDecoder().decode(ServerResponse.self, from: data) else {
                if !rest.isEmpty {
                    self.attemptServer(bases: rest, path: path, code: code, completion: completion)
                } else {
                    entrega(.unreachable)
                }
                return
            }

            if res.ok, let lic = res.license {
                entrega(.success(lic))
                return
            }

            // unknown / invalid genérico en un base remoto: probar el siguiente
            // (p.ej. app.entikmedia.com → :3000 local, o al revés).
            let st = res.status ?? ""
            if !rest.isEmpty, st == "unknown" || (st == "invalid" && !base.contains("127.0.0.1")) {
                self.attemptServer(bases: rest, path: path, code: code, completion: completion)
                return
            }

            entrega(.rejected(
                status: res.status,
                message: Self.mensaje(estado: res.status, error: res.error)
            ))
        }.resume()
    }

    private static func mensaje(estado: String?, error: String?) -> String {
        switch estado {
        case "invalid":        return "El codigo no es valido. Revisa que este bien escrito."
        case "unknown":        return "Ese codigo no consta en el sistema."
        case "revoked":        return "Esta licencia ha sido revocada."
        case "expired":        return "Esta licencia ha caducado."
        case "device_limit":   return error ?? "La licencia ya esta en uso en otro equipo."
        case "device_unknown": return "Este equipo no esta autorizado con esa licencia."
        case "rate_limit":     return "Demasiados intentos. Espera unos minutos."
        default:               return error ?? "No se pudo validar la licencia."
        }
    }

    // ── Persistencia ────────────────────────────────────────────────────────

    private func persist(kind k: LicenseKind, code: String, expires: Date?) {
        defaults.set(k.rawValue, forKey: kKind)
        defaults.set(code, forKey: kCode)
        defaults.set(Date().timeIntervalSince1970, forKey: kSince)
        if let e = expires {
            defaults.set(e.timeIntervalSince1970, forKey: kExpires)
        } else {
            defaults.removeObject(forKey: kExpires)
        }
        refresh()
    }

    private func clearStored() {
        [kKind, kCode, kSince, kExpires].forEach { defaults.removeObject(forKey: $0) }
    }

    private func clearState() {
        isUnlocked = false
        kind = nil
        expiresAt = nil
    }
}
