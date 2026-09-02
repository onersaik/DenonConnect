// WebServer.swift
// Servidor HTTP embebido para monitorizacion remota de decks desde
// cualquier navegador en la misma red. Puerto configurable (por defecto 8080).
//
// Rutas:
//   GET /        -- pagina HTML con auto-refresh cada 2 s
//   GET /api     -- JSON con el estado actual de los decks

import Foundation
import Network

// MARK: - Modelo de estado compartido

public struct DeckSnapshot: Encodable {
    public var label:      String
    public var title:      String
    public var artist:     String
    public var bpm:        Double
    public var isPlaying:  Bool
    public var isMaster:   Bool
    public var elapsed:    Double?
    public var duration:   Double?
    public var progress:   Double?
    public var beatInBar:  Int

    public init(label: String, title: String, artist: String, bpm: Double,
                isPlaying: Bool, isMaster: Bool, elapsed: Double?,
                duration: Double?, progress: Double?, beatInBar: Int) {
        self.label = label; self.title = title; self.artist = artist
        self.bpm = bpm; self.isPlaying = isPlaying; self.isMaster = isMaster
        self.elapsed = elapsed; self.duration = duration
        self.progress = progress; self.beatInBar = beatInBar
    }
}

// MARK: - WebServer

public final class WebServer {

    public var port: UInt16 = 8080
    public var isRunning: Bool { listener != nil }
    public var stateProvider: (() -> [DeckSnapshot])?

    private var listener:    NWListener?
    private var connections: [NWConnection] = []
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
            if case .ready = state {
                self?.log("[Web] Servidor activo en http://localhost:\(self?.port ?? 8080)")
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
        log("[Web] Servidor detenido")
    }

    private func handleConnection(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            let path = Self.parsePath(String(bytes: data, encoding: .utf8) ?? "")
            let resp = path == "/api" ? self.apiResponse() : self.htmlResponse()
            conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func apiResponse() -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted
        let body = (try? encoder.encode(stateProvider?() ?? [])) ?? Data("[]".utf8)
        return httpResponse(200, "application/json", body)
    }

    private func htmlResponse() -> Data {
        httpResponse(200, "text/html; charset=utf-8", Data(Self.monitorHTML.utf8))
    }

    private func httpResponse(_ code: Int, _ ct: String, _ body: Data) -> Data {
        var r = Data("HTTP/1.1 \(code) OK\r\nContent-Type: \(ct)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
        r.append(body); return r
    }

    private static func parsePath(_ req: String) -> String {
        let line = req.split(separator: "\r").first ?? ""
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }

    public enum WebServerError: Error { case listenerFailed }

    // MARK: HTML de monitorizacion

    private static let monitorHTML = """
    <!DOCTYPE html>
    <html lang="es">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>SC6000 Connect</title>
    <style>
    :root{--bg:#0d0d12;--panel:#17171f;--border:#2a2a38;--accent:#f5a623;--green:#00e676;--cyan:#00bcd4;--text:#e8e8f0;--muted:#6b6b82}
    *{box-sizing:border-box;margin:0;padding:0}
    body{background:var(--bg);color:var(--text);font-family:-apple-system,sans-serif;font-size:14px;padding:20px}
    header{display:flex;align-items:center;gap:12px;margin-bottom:20px;padding-bottom:14px;border-bottom:1px solid var(--border)}
    header h1{font-size:16px;font-weight:700;letter-spacing:.8px;color:var(--accent)}
    .dot{width:8px;height:8px;border-radius:50%;background:var(--green);animation:pulse 1.5s infinite}
    @keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px}
    .deck{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:16px;transition:border-color .3s}
    .deck.playing{border-color:var(--accent)}
    .label{font-size:10px;font-weight:700;letter-spacing:.6px;color:var(--muted);margin-bottom:6px}
    .title{font-size:16px;font-weight:600;color:var(--green);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .artist{font-size:12px;color:var(--muted);margin-top:2px}
    .bpm{font-size:28px;font-weight:700;color:var(--green);margin-top:10px;font-variant-numeric:tabular-nums}
    .bpm span{font-size:11px;color:var(--muted);margin-left:3px}
    .beats{display:flex;gap:4px;margin-top:8px}
    .beat{width:18px;height:22px;border-radius:3px;background:rgba(255,255,255,.06)}
    .beat.on{background:var(--accent)}.beat.b1.on{background:var(--green)}
    .bar{height:4px;border-radius:2px;background:rgba(255,255,255,.07);overflow:hidden;margin-top:10px}
    .fill{height:100%;border-radius:2px;background:var(--accent);transition:width .5s}
    .times{display:flex;justify-content:space-between;margin-top:4px;font-size:10px;color:var(--muted);font-variant-numeric:tabular-nums}
    footer{margin-top:24px;text-align:center;font-size:10px;color:var(--muted)}
    </style>
    </head>
    <body>
    <header><div class="dot"></div><h1>SC6000 CONNECT</h1><span style="font-size:11px;color:var(--muted)">Monitor en vivo</span></header>
    <div class="grid" id="g"><p style="color:var(--muted);padding:40px 0;text-align:center">Cargando...</p></div>
    <footer>entikrecords.com</footer>
    <script>
    function fmt(s){if(s==null)return'--:--';const m=Math.floor(s/60),ss=Math.floor(s%60);return String(m).padStart(2,'0')+':'+String(ss).padStart(2,'0')}
    async function refresh(){
      try{
        const d=await(await fetch('/api')).json();
        const g=document.getElementById('g');
        if(!d.length){g.innerHTML='<p style="color:var(--muted);padding:40px 0;text-align:center">Sin decks activos</p>';return}
        g.innerHTML=d.map(x=>{
          const pct=x.progress!=null?(x.progress*100).toFixed(0):null;
          const bs=[1,2,3,4].map(i=>'<div class="beat'+(i===1?' b1':'')+(x.beatInBar===i?' on':'')+'"></div>').join('');
          return '<div class="deck'+(x.isPlaying?' playing':'')+'"><div class="label">'+x.label.toUpperCase()+'</div><div class="title">'+(x.isPlaying?x.title||'&mdash;':'SIN PISTA')+'</div><div class="artist">'+x.artist+'</div><div class="bpm">'+( x.bpm>0?x.bpm.toFixed(2):'---.--')+'<span>BPM</span></div><div class="beats">'+bs+'</div>'+(pct!=null?'<div class="bar"><div class="fill" style="width:'+pct+'%"></div></div><div class="times"><span>'+fmt(x.elapsed)+'</span><span>'+pct+'%</span><span>-'+fmt(x.duration!=null&&x.elapsed!=null?x.duration-x.elapsed:null)+'</span></div>':'')+'</div>'
        }).join('');
      }catch(e){console.error(e)}
    }
    refresh();setInterval(refresh,2000);
    </script>
    </body></html>
    """
}
