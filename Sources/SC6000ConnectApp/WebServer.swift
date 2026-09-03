// WebServer.swift
// Servidor HTTP embebido con SSE y WebSocket para monitorización en vivo.
//
// Rutas:
//   GET /        -- dashboard HTML completo (CDJ style)
//   GET /api     -- JSON con estado actual de todos los decks
//   GET /events  -- SSE stream tiempo real (push cada 250 ms)
//   GET /ws      -- WebSocket, mismo JSON de decks (overlay propio / Resolume)

import Foundation
import Network
import CryptoKit

// MARK: - DeckSnapshot

public struct DeckSnapshot: Encodable {
    public var tag:         String
    public var label:       String
    public var title:       String
    public var artist:      String
    public var key:         String
    public var bpm:         Double
    public var pitchPct:    Double?
    public var isPlaying:   Bool
    public var isMaster:    Bool
    public var isOnAir:     Bool
    public var ltcSource:   Bool
    public var elapsed:     Double?
    public var playhead:    Double?
    public var duration:    Double?
    public var progress:    Double?
    public var beatInBar:   Int
    public var tcTimecode:  String?
    public var peaks:       [UInt8]?
    public var peaksLow:    [UInt8]?
    public var peaksMid:    [UInt8]?
    public var peaksHigh:   [UInt8]?

    public init(label: String, title: String, artist: String, bpm: Double,
                isPlaying: Bool, isMaster: Bool, elapsed: Double?,
                duration: Double?, progress: Double?, beatInBar: Int,
                key: String = "", pitchPct: Double? = nil,
                isOnAir: Bool = false, ltcSource: Bool = false,
                tcTimecode: String? = nil, tag: String = "",
                peaks: [UInt8]? = nil, peaksLow: [UInt8]? = nil,
                peaksMid: [UInt8]? = nil, peaksHigh: [UInt8]? = nil) {
        self.tag = tag.isEmpty ? label : tag
        self.label = label; self.title = title; self.artist = artist
        self.key = key; self.bpm = bpm; self.pitchPct = pitchPct
        self.isPlaying = isPlaying; self.isMaster = isMaster
        self.isOnAir = isOnAir; self.ltcSource = ltcSource
        self.elapsed = elapsed; self.playhead = elapsed
        self.duration = duration
        self.progress = progress; self.beatInBar = beatInBar
        self.tcTimecode = tcTimecode
        self.peaks = peaks
        self.peaksLow = peaksLow
        self.peaksMid = peaksMid
        self.peaksHigh = peaksHigh
    }
}

// MARK: - WebServer

public final class WebServer {

    public var port: UInt16 = 8080
    public var isRunning: Bool { listener != nil }
    public var stateProvider: (() -> [DeckSnapshot])?
    /// Tracklist público (sin secretos). Misma forma que el bridge :3000.
    public var tracklistProvider: (() -> [String: Any])?
    /// Puerto ocupado u otro fallo de bind. Se llama fuera del hilo de UI.
    public var failureHandler: ((String) -> Void)?

    private var listener:    NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sseClients:  [ObjectIdentifier: NWConnection] = [:]
    private var wsClients:   [ObjectIdentifier: NWConnection] = [:]
    private var pushTimer:   DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.sc6000connect.webserver", qos: .utility)
    private let log: (String) -> Void

    public init(log: @escaping (String) -> Void = { _ in }) { self.log = log }

    // MARK: Control

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params,
                                       on: NWEndpoint.Port(rawValue: port) ?? 8080)
        else { throw WebServerError.listenerFailed }

        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("[Web] http://localhost:\(self.port)  ·  /obs  ·  /ws")
            case .failed(let err):
                let raw = err as NSError
                let msg: String
                if raw.domain == NSPOSIXErrorDomain, raw.code == EADDRINUSE {
                    msg = "Puerto \(self.port) ocupado. Cambia el puerto o cierra la otra app que lo usa."
                } else {
                    msg = "No se pudo abrir el puerto \(self.port)."
                }
                self.log("[Web] \(msg)")
                self.failureHandler?(msg)
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
        l.start(queue: queue)
        listener = l
        startPushTimer()
    }

    public func stop() {
        pushTimer?.cancel(); pushTimer = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        sseClients.removeAll()
        wsClients.removeAll()
        log("[Web] Servidor detenido")
    }

    // MARK: SSE timer (100 ms = 10 fps tiempo real)

    private func startPushTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.broadcastLive() }
        t.resume()
        pushTimer = t
    }

    private func broadcastLive() {
        if sseClients.isEmpty && wsClients.isEmpty { return }
        guard let str = livePayloadString() else { return }
        if !sseClients.isEmpty {
            let frame = Data("data: \(str)\n\n".utf8)
            pruneAndSend(sseClients, payload: frame) { sseClients = $0 }
        }
        if !wsClients.isEmpty {
            let frame = Self.wsTextFrame(str)
            pruneAndSend(wsClients, payload: frame) { wsClients = $0 }
        }
    }

    /// Envelope igual que Express `/api/monitor`: tc + decks + tracklist.
    private func livePayloadDict() -> [String: Any] {
        let snaps = stateProvider?() ?? []
        let tc = snaps.first(where: { $0.ltcSource })?.tcTimecode
            ?? snaps.first(where: { $0.isMaster })?.tcTimecode
            ?? snaps.first(where: { $0.isPlaying })?.tcTimecode
            ?? snaps.compactMap(\.tcTimecode).first
            ?? "00:00:00:00"
        let encoder = JSONEncoder()
        let decksObj: Any
        if let data = try? encoder.encode(snaps),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            decksObj = obj
        } else {
            decksObj = []
        }
        var tl = tracklistProvider?() ?? [:]
        if tl.isEmpty {
            tl = ["items": [], "notes": "", "annotations": [], "tc": tc, "currentId": NSNull()]
        }
        return [
            "tc": tc,
            "decks": decksObj,
            "tracklist": tl,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
    }

    private func livePayloadString() -> String? {
        let dict = livePayloadDict()
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func livePayloadData() -> Data {
        if let data = try? JSONSerialization.data(withJSONObject: livePayloadDict()) {
            return data
        }
        return Data("{}".utf8)
    }

    private func pruneAndSend(
        _ clients: [ObjectIdentifier: NWConnection],
        payload: Data,
        store: ([ObjectIdentifier: NWConnection]) -> Void
    ) {
        var live = clients
        var dead: [ObjectIdentifier] = []
        for (key, conn) in live {
            if case .cancelled = conn.state { dead.append(key); continue }
            if case .failed    = conn.state { dead.append(key); continue }
            conn.send(content: payload, completion: .idempotent)
        }
        dead.forEach { live.removeValue(forKey: $0) }
        store(live)
    }

    // MARK: Connection handling

    private func handleConnection(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                conn.cancel()
                self?.connections.removeValue(forKey: key)
                return
            }
            let req  = String(bytes: data, encoding: .utf8) ?? ""
            let path = Self.parsePath(req)
            switch path {
            case "/obs":
                let transparent = Self.parseQuery(req)["t"] == "1"
                let resp = self.obsResponse(transparent: transparent)
                conn.send(content: resp, completion: .contentProcessed { _ in
                    conn.cancel()
                    self.connections.removeValue(forKey: key)
                })
            case "/events", "/api/monitor/events":
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n"
                conn.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
                self.sseClients[key] = conn
                if let str = self.livePayloadString() {
                    conn.send(content: Data("data: \(str)\n\n".utf8), completion: .idempotent)
                }
            case "/ws":
                self.upgradeWebSocket(conn, request: req, key: key)
            case "/monitor", "/", "":
                let resp = self.htmlResponse()
                conn.send(content: resp, completion: .contentProcessed { _ in
                    conn.cancel()
                    self.connections.removeValue(forKey: key)
                })
            case "/api/monitor":
                let resp = self.httpResponse(200, "application/json", self.livePayloadData())
                conn.send(content: resp, completion: .contentProcessed { _ in
                    conn.cancel()
                    self.connections.removeValue(forKey: key)
                })
            case "/api":
                let resp = self.apiResponse()
                conn.send(content: resp, completion: .contentProcessed { _ in
                    conn.cancel()
                    self.connections.removeValue(forKey: key)
                })
            default:
                // /query y el resto no son el dashboard: VirtualDJ sondea
                // :8080/query y un 200 HTML lo tomaba por Network Control.
                let body = Data("not found".utf8)
                conn.send(content: self.httpResponse(404, "text/plain; charset=utf-8", body),
                          completion: .contentProcessed { _ in
                    conn.cancel()
                    self.connections.removeValue(forKey: key)
                })
            }
        }
    }

    private func apiResponse() -> Data {
        httpResponse(200, "application/json", livePayloadData())
    }

    private func monitorResponse() -> Data {
        httpResponse(200, "application/json", livePayloadData())
    }

    private func htmlResponse() -> Data {
        httpResponse(200, "text/html; charset=utf-8", Data(Self.monitorHTML.utf8))
    }

    private func obsResponse(transparent: Bool) -> Data {
        httpResponse(200, "text/html; charset=utf-8", Data(Self.obsHTML(transparent: transparent).utf8))
    }

    private func httpResponse(_ code: Int, _ ct: String, _ body: Data) -> Data {
        var r = Data("HTTP/1.1 \(code) OK\r\nContent-Type: \(ct)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
        r.append(body); return r
    }

    private static func parsePath(_ req: String) -> String {
        let line  = req.split(separator: "\r").first ?? ""
        let parts = line.split(separator: " ")
        let raw = parts.count >= 2 ? String(parts[1]) : "/"
        return raw.split(separator: "?").first.map(String.init) ?? raw
    }

    private static func parseQuery(_ req: String) -> [String: String] {
        let line  = req.split(separator: "\r").first ?? ""
        let parts = line.split(separator: " ")
        let raw = parts.count >= 2 ? String(parts[1]) : "/"
        guard let q = raw.split(separator: "?").dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if let k = kv.first { out[String(k)] = kv.count > 1 ? String(kv[1]) : "" }
        }
        return out
    }

    private static func headerValue(_ req: String, _ name: String) -> String? {
        for line in req.split(whereSeparator: \.isNewline) {
            let s = String(line)
            if s.lowercased().hasPrefix(name.lowercased() + ":") {
                return s.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func upgradeWebSocket(_ conn: NWConnection, request: String, key: ObjectIdentifier) {
        let upgrade = (Self.headerValue(request, "Upgrade") ?? "").lowercased()
        guard upgrade.contains("websocket"),
              let wsKey = Self.headerValue(request, "Sec-WebSocket-Key"), !wsKey.isEmpty else {
            let body = Data("WebSocket: conecta a ws://host:\(port)/ws".utf8)
            conn.send(content: httpResponse(400, "text/plain; charset=utf-8", body),
                      completion: .contentProcessed { _ in
                conn.cancel()
                self.connections.removeValue(forKey: key)
            })
            return
        }
        let accept = Self.wsAccept(wsKey)
        let headers = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
        wsClients[key] = conn
        log("[Web] WebSocket conectado")
    }

    private static func wsAccept(_ key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func wsTextFrame(_ text: String) -> Data {
        let payload = Array(text.utf8)
        var frame = Data()
        frame.append(0x81)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            var n = UInt64(len).bigEndian
            withUnsafeBytes(of: &n) { frame.append(contentsOf: $0) }
        }
        frame.append(contentsOf: payload)
        return frame
    }

    public enum WebServerError: Error { case listenerFailed }

    // MARK: HTML Dashboard CDJ

    private static let monitorHTML = #"""
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#07070c">
<title>STAGE CONNECT · Monitor</title>
<style>
:root{
  --bg:#07070c;--panel:#101018;--strip:#0c0c12;--elev:#15151f;
  --border:rgba(255,255,255,.08);--accent:#f57a18;--green:#00e676;
  --yellow:#ffd54f;--red:#ff4060;--text:#ececf4;--muted:#7a7a92;--dim:#2e2e40;
  --safe-b:env(safe-area-inset-bottom,0px);--safe-t:env(safe-area-inset-top,0px);
  --mono:ui-monospace,'SF Mono',Menlo,Consolas,monospace;
  --sans:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;
}
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{
  background:
    radial-gradient(1200px 600px at 10% -10%,rgba(245,122,24,.12),transparent 55%),
    radial-gradient(900px 500px at 100% 0%,rgba(0,230,118,.06),transparent 50%),
    var(--bg);
  color:var(--text);font-family:var(--sans);
  min-height:100dvh;display:flex;flex-direction:column;
  padding-top:var(--safe-t);-webkit-tap-highlight-color:transparent;
}
.app-header{
  display:flex;align-items:center;gap:12px;flex-wrap:wrap;
  padding:12px 16px;border-bottom:1px solid var(--border);
  background:linear-gradient(180deg,rgba(16,16,24,.96),rgba(12,12,18,.92));
  backdrop-filter:blur(12px);position:sticky;top:0;z-index:20;
}
.brand{font-size:12px;font-weight:800;letter-spacing:2.2px;color:var(--accent)}
.live{display:inline-flex;align-items:center;gap:6px;font-size:10px;font-weight:700;letter-spacing:.8px;color:var(--green)}
.dot{width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 10px rgba(0,230,118,.55);animation:pulse 1.4s ease-in-out infinite}
.dot.off{background:var(--muted);box-shadow:none;animation:none}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
.tc-master{margin-left:auto;font:800 clamp(22px,5vw,34px)/1 var(--mono);letter-spacing:1px;color:var(--green)}
.meta-line{width:100%;font:10px/1.4 var(--mono);color:var(--muted)}
.tabs{
  display:flex;gap:4px;padding:8px 12px;overflow-x:auto;-webkit-overflow-scrolling:touch;
  border-bottom:1px solid var(--border);background:var(--strip);scrollbar-width:none;
}
.tabs::-webkit-scrollbar{display:none}
.tab{
  flex:0 0 auto;border:0;cursor:pointer;font:700 11px/1 var(--sans);
  letter-spacing:.7px;text-transform:uppercase;color:var(--muted);
  padding:10px 14px;background:transparent;border-radius:4px;
  transition:background .15s,color .15s;
}
.tab[aria-selected="true"]{background:var(--accent);color:#0a0a0a}
.tab:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.stage{flex:1;min-height:0;overflow:auto;padding:14px 14px calc(18px + var(--safe-b))}
.panel{display:none}
.panel.active{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,340px),1fr));gap:12px}
.deck{
  background:linear-gradient(165deg,var(--panel),var(--elev));
  border:1px solid var(--border);border-radius:10px;overflow:hidden;
  box-shadow:0 10px 30px rgba(0,0,0,.28);
}
.deck.playing{border-color:rgba(245,122,24,.5)}
.deck.master{border-color:rgba(0,230,118,.45)}
.deck-inner{padding:14px}
.label{font-size:9px;font-weight:800;letter-spacing:1.3px;color:var(--muted);margin-bottom:8px}
.row{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
.title{font-size:16px;font-weight:700;color:var(--green);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.artist{font-size:12px;color:var(--muted);margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bpm{font:800 28px/1 var(--mono);color:var(--green);letter-spacing:-1px}
.bpm-label{font-size:8px;font-weight:700;color:var(--muted);letter-spacing:.8px;text-align:right;margin-top:4px}
.badges{display:flex;gap:4px;flex-wrap:wrap;margin-top:8px}
.badge{font-size:8px;font-weight:800;letter-spacing:.7px;padding:3px 7px;border-radius:3px}
.badge.master{background:var(--green);color:#000}
.badge.air{background:var(--red);color:#000}
.badge.ltc{background:var(--accent);color:#000}
.badge.play{color:var(--green);background:rgba(0,230,118,.12)}
.badge.pause{color:var(--muted);background:rgba(255,255,255,.06)}
.wave-wrap{position:relative;height:56px;margin-top:12px;background:#000;border-radius:6px;overflow:hidden}
.wave-wrap canvas{width:100%;height:100%;display:block}
.playhead{position:absolute;top:0;bottom:0;width:2px;background:#fff;left:50%;transform:translateX(-50%);box-shadow:0 0 8px rgba(255,255,255,.45);pointer-events:none}
.beats{display:flex;gap:3px;margin-top:10px}
.beat{height:12px;flex:1;border-radius:2px;background:rgba(255,255,255,.06)}
.beat.on{background:var(--accent)}
.beat.b1.on{background:var(--green)}
.meta{display:flex;justify-content:space-between;margin-top:8px;font:11px var(--mono);color:var(--muted)}
.meta .el{color:var(--text)}
.empty{text-align:center;padding:64px 20px;color:var(--muted);font-size:14px;line-height:1.65}
.master-hero{
  background:linear-gradient(160deg,rgba(245,122,24,.14),transparent 42%),var(--panel);
  border:1px solid var(--border);border-radius:12px;padding:22px 20px;margin-bottom:14px;
}
.master-kicker{font-size:10px;font-weight:800;letter-spacing:1.8px;color:var(--accent);margin-bottom:8px}
.master-title{font-size:clamp(22px,5vw,34px);font-weight:800;line-height:1.15;margin-bottom:6px}
.master-artist{font-size:15px;color:var(--muted);margin-bottom:16px}
.master-stats{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
.stat{background:rgba(0,0,0,.28);border:1px solid var(--border);border-radius:8px;padding:12px}
.stat .k{font-size:9px;font-weight:700;letter-spacing:1px;color:var(--muted);margin-bottom:6px}
.stat .v{font:800 clamp(18px,4vw,28px)/1 var(--mono);color:var(--green)}
.info-card,.tl-card{
  background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:16px;margin-bottom:12px;
}
.info-card h3,.tl-card h3{font-size:11px;letter-spacing:1.4px;color:var(--accent);margin-bottom:10px}
.info-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.info-item{background:rgba(255,255,255,.03);border-radius:8px;padding:12px}
.info-item .k{font-size:9px;color:var(--muted);letter-spacing:.8px;margin-bottom:4px}
.info-item .v{font:600 14px/1.3 var(--sans);word-break:break-word}
.tl-now{
  background:linear-gradient(135deg,rgba(245,122,24,.18),rgba(0,0,0,.2));
  border:1px solid rgba(245,122,24,.35);border-radius:12px;padding:18px;margin-bottom:14px;
}
.tl-now .tag{display:inline-block;font-size:9px;font-weight:800;letter-spacing:1px;background:var(--accent);color:#000;padding:3px 8px;border-radius:3px;margin-bottom:10px}
.tl-now .title{font-size:clamp(20px,4.5vw,30px);font-weight:800;margin-bottom:4px}
.tl-now .artist{color:var(--muted);margin-bottom:10px}
.tl-notes{color:var(--yellow);font-weight:600;margin-bottom:10px}
.tl-cues{display:flex;flex-wrap:wrap;gap:6px}
.tl-cue{background:var(--accent);color:#000;font-size:11px;font-weight:800;padding:5px 10px;border-radius:4px}
.tl-row{
  display:flex;gap:12px;align-items:flex-start;padding:12px 14px;
  border-bottom:1px solid var(--border);background:rgba(255,255,255,.015);
}
.tl-row.active{background:rgba(245,122,24,.12);border-left:3px solid var(--accent)}
.tl-row.played:not(.active){opacity:.55}
.tl-num{font:700 13px var(--mono);color:var(--muted);width:28px;flex:none;padding-top:2px}
.tl-body{min-width:0;flex:1}
.tl-body .t{font-weight:700;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tl-body .a{font-size:12px;color:var(--muted);margin-top:2px}
.tl-tc{font:700 11px var(--mono);color:var(--green);flex:none}
.tl-badge{font-size:9px;font-weight:800;background:var(--accent);color:#000;padding:3px 7px;border-radius:3px;align-self:center}
footer{text-align:center;padding:8px 12px calc(10px + var(--safe-b));font-size:10px;color:var(--dim);letter-spacing:.4px}
@media (max-width:560px){
  .app-header{padding:10px 12px;gap:8px}
  .tc-master{margin-left:0;width:100%;order:3}
  .meta-line{order:4}
  .master-stats{grid-template-columns:1fr}
  .info-grid{grid-template-columns:1fr}
}
@media (min-width:900px){
  .stage{padding:18px 22px 24px}
  .grid{gap:16px}
}
</style>
</head>
<body>
<header class="app-header">
  <div class="brand">STAGE CONNECT</div>
  <div class="live"><div class="dot off" id="dot"></div><span id="liveLabel">CONECTANDO…</span></div>
  <div class="tc-master" id="tc">00:00:00:00</div>
  <div class="meta-line" id="status">Monitor cabina · SSE local</div>
</header>
<nav class="tabs" role="tablist" aria-label="Vistas del monitor">
  <button class="tab" role="tab" id="tab-players" aria-selected="true" data-tab="players">Reproductores</button>
  <button class="tab" role="tab" id="tab-master" aria-selected="false" data-tab="master">Master</button>
  <button class="tab" role="tab" id="tab-info" aria-selected="false" data-tab="info">Info</button>
  <button class="tab" role="tab" id="tab-tracklist" aria-selected="false" data-tab="tracklist">Tracklist</button>
  <button class="tab" role="tab" id="tab-monitor" aria-selected="false" data-tab="monitor">Monitor</button>
</nav>
<main class="stage">
  <section class="panel active" id="panel-players" role="tabpanel"></section>
  <section class="panel" id="panel-master" role="tabpanel"></section>
  <section class="panel" id="panel-info" role="tabpanel"></section>
  <section class="panel" id="panel-tracklist" role="tabpanel"></section>
  <section class="panel" id="panel-monitor" role="tabpanel"></section>
</main>
<footer>Monitor en vivo · sin secretos · entikrecords.com</footer>
<script>
(function(){
const TAB_KEY='sc.monitor.tab';
let state={tc:'00:00:00:00',decks:[],tracklist:{items:[],notes:'',annotations:[],currentId:null},updatedAt:null};
let last=0,es=null,retry=null,activeTab=localStorage.getItem(TAB_KEY)||'players';
function esc(s){return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function fmt(s){
  if(s==null||!isFinite(s))return'--:--';
  const m=Math.floor(s/60),ss=Math.floor(s%60);
  return String(m).padStart(2,'0')+':'+String(ss).padStart(2,'0');
}
function paintWave(canvas,d){
  const w=canvas.width=Math.max(1,canvas.clientWidth*devicePixelRatio);
  const h=canvas.height=Math.max(1,canvas.clientHeight*devicePixelRatio);
  const ctx=canvas.getContext('2d');
  ctx.clearRect(0,0,w,h);
  const peaks=d.peaksLow&&d.peaksLow.length?d.peaksLow:(d.peaks||[]);
  const mid=d.peaksMid||[];
  const high=d.peaksHigh||[];
  const n=Math.max(peaks.length,64);
  const midY=h/2;
  ctx.fillStyle='#050508';
  ctx.fillRect(0,0,w,h);
  for(let i=0;i<n;i++){
    const x=(i/n)*w;
    const bw=Math.max(1,w/n*0.85);
    const v=(peaks[i%Math.max(peaks.length,1)]|0)/255;
    const vm=(mid[i%Math.max(mid.length,1)]|0)/255;
    const vh=(high[i%Math.max(high.length,1)]|0)/255;
    const amp=Math.max(0.08,(v*0.55+vm*0.3+vh*0.15))*midY*0.92;
    ctx.fillStyle='rgb(245,'+Math.floor(90+v*80)+','+Math.floor(20+vh*40)+')';
    ctx.fillRect(x,midY-amp,bw,amp*2);
  }
}
function masterDeck(decks){
  return decks.find(d=>d.isMaster)||decks.find(d=>d.ltcSource)||decks.find(d=>d.isPlaying)||decks[0]||null;
}
function deckCard(d,i){
  const playing=d.isPlaying, master=d.isMaster;
  const head=d.playhead!=null?d.playhead:d.elapsed;
  const beats=[1,2,3,4].map(b=>'<div class="beat'+(b===1?' b1':'')+(d.beatInBar===b?' on':'')+'"></div>').join('');
  const badges=[
    master?'<span class="badge master">MASTER</span>':'',
    d.isOnAir?'<span class="badge air">ON AIR</span>':'',
    d.ltcSource?'<span class="badge ltc">LTC</span>':'',
    playing?'<span class="badge play">PLAY</span>':'<span class="badge pause">PAUSE</span>'
  ].join('');
  const rem=(d.duration!=null&&head!=null)?Math.max(0,d.duration-head):null;
  return '<article class="deck'+(playing?' playing':'')+(master?' master':'')+'">'+
    '<div class="deck-inner">'+
    '<div class="label">'+esc((d.label||d.tag||('DECK '+(i+1))).toUpperCase())+'</div>'+
    '<div class="row"><div style="min-width:0;flex:1">'+
    '<div class="title">'+(playing||d.title?esc(d.title||'—'):'SIN PISTA')+'</div>'+
    '<div class="artist">'+esc(d.artist||'')+'</div>'+
    '<div class="badges">'+badges+'</div></div>'+
    '<div><div class="bpm">'+(d.bpm>0?d.bpm.toFixed(2):'---.--')+'</div><div class="bpm-label">BPM</div></div></div>'+
    '<div class="wave-wrap"><canvas data-i="'+i+'"></canvas><div class="playhead"></div></div>'+
    '<div class="beats">'+beats+'</div>'+
    '<div class="meta"><span class="el">'+fmt(head)+'</span><span>'+(d.tcTimecode?esc(d.tcTimecode):'')+'</span><span>'+(rem!=null?'-'+fmt(rem):'')+'</span></div>'+
    '</div></article>';
}
function renderPlayers(root,decks){
  if(!decks.length){
    root.innerHTML='<div class="empty">Sin decks activos<br>Carga una pista en Denon / Pioneer / Serato / VDJ</div>';
    return;
  }
  root.innerHTML='<div class="grid">'+decks.map(deckCard).join('')+'</div>';
  root.querySelectorAll('canvas').forEach(c=>{
    const i=+c.getAttribute('data-i');
    paintWave(c,decks[i]||{});
  });
}
function renderMaster(root,decks,tc){
  const m=masterDeck(decks);
  if(!m){
    root.innerHTML='<div class="empty">Sin MASTER<br>Activa LTC o pon un deck en play</div>';
    return;
  }
  const head=m.playhead!=null?m.playhead:m.elapsed;
  root.innerHTML=
    '<div class="master-hero">'+
    '<div class="master-kicker">MASTER</div>'+
    '<div class="master-title">'+esc(m.title||'SIN PISTA')+'</div>'+
    '<div class="master-artist">'+esc(m.artist||m.label||'')+'</div>'+
    '<div class="master-stats">'+
    '<div class="stat"><div class="k">TIMECODE</div><div class="v">'+esc(tc||m.tcTimecode||'00:00:00:00')+'</div></div>'+
    '<div class="stat"><div class="k">BPM</div><div class="v">'+(m.bpm>0?m.bpm.toFixed(2):'—')+'</div></div>'+
    '<div class="stat"><div class="k">PLAYHEAD</div><div class="v">'+fmt(head)+'</div></div>'+
    '</div></div>'+
    '<div class="grid">'+deckCard(m,0)+'</div>';
  const c=root.querySelector('canvas');
  if(c) paintWave(c,m);
}
function renderInfo(root,st){
  const decks=st.decks||[];
  const m=masterDeck(decks);
  const playing=decks.filter(d=>d.isPlaying).length;
  const tl=st.tracklist||{};
  root.innerHTML=
    '<div class="info-card"><h3>SESIÓN</h3><div class="info-grid">'+
    '<div class="info-item"><div class="k">TC SHOW</div><div class="v">'+esc(st.tc||'—')+'</div></div>'+
    '<div class="info-item"><div class="k">DECKS</div><div class="v">'+decks.length+' · '+playing+' en play</div></div>'+
    '<div class="info-item"><div class="k">MASTER</div><div class="v">'+esc(m?(m.label||m.tag||'—'):'—')+'</div></div>'+
    '<div class="info-item"><div class="k">ACTUALIZADO</div><div class="v">'+esc(st.updatedAt?new Date(st.updatedAt).toLocaleTimeString('es',{hour12:false}):'—')+'</div></div>'+
    '</div></div>'+
    '<div class="info-card"><h3>TRACKLIST</h3><div class="info-grid">'+
    '<div class="info-item"><div class="k">PISTAS</div><div class="v">'+(tl.items?tl.items.length:0)+'</div></div>'+
    '<div class="info-item"><div class="k">ACTIVA</div><div class="v">'+esc((tl.items||[]).find(i=>i.active)?.title||'—')+'</div></div>'+
    '<div class="info-item"><div class="k">NOTAS</div><div class="v">'+esc(tl.notes||'—')+'</div></div>'+
    '<div class="info-item"><div class="k">CUES VIVOS</div><div class="v">'+(tl.annotations?tl.annotations.length:0)+'</div></div>'+
    '</div></div>'+
    '<div class="info-card"><h3>ORIGEN</h3><p style="color:var(--muted);font-size:13px;line-height:1.5">Datos en vivo desde la app Mac (:8080). Sin tokens ni licencias en el cliente. Express :3000 sigue disponible para el túnel público.</p></div>';
}
function renderTracklist(root,tl,tc){
  tl=tl||{items:[],annotations:[],notes:''};
  const items=tl.items||[];
  const active=items.find(i=>i.active)||items.find(i=>i.id&&i.id===tl.currentId);
  let html='';
  if(active||tl.notes||(tl.annotations&&tl.annotations.length)){
    html+='<div class="tl-now"><div class="tag">AHORA</div>'+
      '<div class="title">'+esc(active?active.title:'—')+'</div>'+
      '<div class="artist">'+esc(active?(active.artist||''):'')+'</div>'+
      (tl.notes?'<div class="tl-notes">'+esc(tl.notes)+'</div>':'')+
      ((tl.annotations&&tl.annotations.length)?'<div class="tl-cues">'+tl.annotations.map(a=>'<span class="tl-cue">'+esc(a.text)+'</span>').join('')+'</div>':'')+
      '</div>';
  }
  if(!items.length){
    html+='<div class="empty">Tracklist vacío<br>Edita la lista en la app Mac y enlaza cada pista a un TC</div>';
  } else {
    html+='<div class="tl-card" style="padding:0;overflow:hidden">'+
      '<div style="padding:14px 16px 8px"><h3>SET · TC '+esc(tl.tc||tc||'')+'</h3></div>'+
      items.map((it,i)=>{
        const cls='tl-row'+(it.active?' active':'')+(it.played?' played':'');
        return '<div class="'+cls+'">'+
          '<div class="tl-num">'+String(i+1).padStart(2,'0')+'</div>'+
          '<div class="tl-body"><div class="t">'+esc(it.title||'—')+'</div>'+
          '<div class="a">'+esc([it.tc,it.artist,it.notes].filter(Boolean).join(' · '))+'</div></div>'+
          (it.tc?'<div class="tl-tc">'+esc(it.tc)+'</div>':'')+
          (it.active?'<div class="tl-badge">AHORA</div>':'')+
          '</div>';
      }).join('')+'</div>';
  }
  root.innerHTML=html;
}
function renderMonitor(root,decks,tc){
  const m=masterDeck(decks);
  root.innerHTML=
    '<div class="master-hero" style="text-align:center">'+
    '<div class="master-kicker">MONITOR TC</div>'+
    '<div style="font:800 clamp(42px,12vw,96px)/1 var(--mono);color:var(--green);letter-spacing:1px;margin:12px 0 18px">'+esc(tc||'00:00:00:00')+'</div>'+
    '<div class="master-title" style="font-size:18px">'+esc(m?(m.title||'SIN PISTA'):'Esperando decks')+'</div>'+
    '<div class="master-artist">'+esc(m?(m.artist||m.label||''):'')+'</div></div>'+
    (decks.length?'<div class="grid">'+decks.map(deckCard).join('')+'</div>':'');
  root.querySelectorAll('canvas').forEach(c=>{
    const i=+c.getAttribute('data-i');
    paintWave(c,decks[i]||{});
  });
}
function setTab(name){
  activeTab=name;
  localStorage.setItem(TAB_KEY,name);
  document.querySelectorAll('.tab').forEach(t=>{
    const on=t.dataset.tab===name;
    t.setAttribute('aria-selected',on?'true':'false');
  });
  document.querySelectorAll('.panel').forEach(p=>{
    p.classList.toggle('active',p.id==='panel-'+name);
  });
  paint();
}
function paint(){
  const decks=state.decks||[];
  document.getElementById('tc').textContent=state.tc||'00:00:00:00';
  document.getElementById('status').textContent=
    new Date().toLocaleTimeString('es',{hour12:false})+' · '+decks.length+' deck'+(decks.length===1?'':'s')+
    ' · tracklist '+(state.tracklist&&state.tracklist.items?state.tracklist.items.length:0);
  const map={
    players:()=>renderPlayers(document.getElementById('panel-players'),decks),
    master:()=>renderMaster(document.getElementById('panel-master'),decks,state.tc),
    info:()=>renderInfo(document.getElementById('panel-info'),state),
    tracklist:()=>renderTracklist(document.getElementById('panel-tracklist'),state.tracklist,state.tc),
    monitor:()=>renderMonitor(document.getElementById('panel-monitor'),decks,state.tc),
  };
  (map[activeTab]||map.players)();
}
function normalize(raw){
  if(Array.isArray(raw)) return {tc:'00:00:00:00',decks:raw,tracklist:{items:[],annotations:[],notes:''}};
  return raw||state;
}
function render(next){
  last=Date.now();
  state=normalize(next);
  if(!state.tracklist) state.tracklist={items:[],annotations:[],notes:''};
  document.getElementById('dot').className='dot';
  document.getElementById('liveLabel').textContent='EN VIVO';
  paint();
}
function connect(){
  if(es){es.close();es=null}
  es=new EventSource('/events');
  es.onmessage=e=>{try{render(JSON.parse(e.data))}catch(_){}};
  es.onerror=()=>{
    document.getElementById('dot').className='dot off';
    document.getElementById('liveLabel').textContent='RECONECTANDO…';
    es.close();es=null;
    clearTimeout(retry);retry=setTimeout(connect,1500);
  };
}
document.querySelectorAll('.tab').forEach(t=>{
  t.addEventListener('click',()=>setTab(t.dataset.tab));
});
setTab(activeTab);
connect();
setInterval(()=>{
  if(Date.now()-last>4000){
    fetch('/api/monitor').then(r=>r.json()).then(render).catch(()=>{});
  }
},2000);
window.addEventListener('resize',()=>{
  if(activeTab==='players'||activeTab==='master'||activeTab==='monitor') paint();
});
})();
</script>
</body>
</html>
"""#

    private static func obsHTML(transparent: Bool) -> String {
        let bg = transparent ? "transparent" : "#000"
        return #"""
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>STAGE CONNECT</title>
<style>
html,body{margin:0;padding:0;width:1920px;height:1080px;overflow:hidden;background:\#(bg);color:#fff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
.wrap{display:flex;flex-direction:column;height:1080px;padding:36px 48px;box-sizing:border-box}
.tc{font:800 168px/0.9 'SF Mono','Menlo',monospace;letter-spacing:-4px;color:#fff;text-shadow:0 0 24px rgba(0,0,0,.55)}
.master{margin-top:8px;font-size:28px;font-weight:700;letter-spacing:2px;color:#00e676}
.decks{margin-top:auto;display:grid;grid-template-columns:repeat(4,1fr);gap:18px}
.deck{min-height:118px}
.tag{font-size:13px;font-weight:800;letter-spacing:1.4px;color:#8a8a9a}
.play{color:#00e676}
.title{font-size:22px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bpm{font:700 20px 'SF Mono',monospace;color:#f5a623}
</style>
</head>
<body>
<div class="wrap">
  <div class="tc" id="tc">00:00:00:00</div>
  <div class="master" id="master"></div>
  <div class="decks" id="decks"></div>
</div>
<script>
function esc(s){return(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;')}
function paint(raw){
  const decks=Array.isArray(raw)?raw:(raw&&raw.decks)||[];
  const master=decks.find(d=>d.isMaster)||decks.find(d=>d.isPlaying)||decks[0];
  const tc=(raw&&raw.tc)||(master&&master.tcTimecode)||(decks.find(d=>d.tcTimecode)||{}).tcTimecode||'00:00:00:00';
  document.getElementById('tc').textContent=tc;
  document.getElementById('master').textContent=master?(master.title||''):'';
  document.getElementById('decks').innerHTML=decks.slice(0,4).map(d=>`
    <div class="deck">
      <div class="tag${d.isPlaying?' play':''}">${esc((d.tag||d.label||'').toUpperCase())}${d.isPlaying?'  PLAY':''}</div>
      <div class="title">${esc(d.title||'—')}</div>
      <div class="bpm">${d.bpm>0?d.bpm.toFixed(2)+' BPM':''}</div>
    </div>`).join('');
}
const ev=new EventSource('/events');
ev.onmessage=e=>{try{paint(JSON.parse(e.data))}catch(_){}};
</script>
</body>
</html>
"""#
    }
}
