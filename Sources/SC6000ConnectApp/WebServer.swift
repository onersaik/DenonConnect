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

    public init(label: String, title: String, artist: String, bpm: Double,
                isPlaying: Bool, isMaster: Bool, elapsed: Double?,
                duration: Double?, progress: Double?, beatInBar: Int,
                key: String = "", pitchPct: Double? = nil,
                isOnAir: Bool = false, ltcSource: Bool = false,
                tcTimecode: String? = nil, tag: String = "") {
        self.tag = tag.isEmpty ? label : tag
        self.label = label; self.title = title; self.artist = artist
        self.key = key; self.bpm = bpm; self.pitchPct = pitchPct
        self.isPlaying = isPlaying; self.isMaster = isMaster
        self.isOnAir = isOnAir; self.ltcSource = ltcSource
        self.elapsed = elapsed; self.playhead = elapsed
        self.duration = duration
        self.progress = progress; self.beatInBar = beatInBar
        self.tcTimecode = tcTimecode
    }
}

// MARK: - WebServer

public final class WebServer {

    public var port: UInt16 = 8080
    public var isRunning: Bool { listener != nil }
    public var stateProvider: (() -> [DeckSnapshot])?
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

    // MARK: SSE timer (250 ms = 4 fps tiempo real)

    private func startPushTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.broadcastLive() }
        t.resume()
        pushTimer = t
    }

    private func broadcastLive() {
        if sseClients.isEmpty && wsClients.isEmpty { return }
        let snaps = stateProvider?() ?? []
        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(snaps),
              let str  = String(data: json, encoding: .utf8) else { return }
        if !sseClients.isEmpty {
            let frame = Data("data: \(str)\n\n".utf8)
            pruneAndSend(sseClients, payload: frame) { sseClients = $0 }
        }
        if !wsClients.isEmpty {
            let frame = Self.wsTextFrame(str)
            pruneAndSend(wsClients, payload: frame) { wsClients = $0 }
        }
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
            case "/events":
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n"
                conn.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
                self.sseClients[key] = conn
            case "/ws":
                self.upgradeWebSocket(conn, request: req, key: key)
            case "/monitor":
                let resp = self.monitorResponse()
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
            case "/", "":
                let resp = self.htmlResponse()
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
        let encoder = JSONEncoder()
        let body = (try? encoder.encode(stateProvider?() ?? [])) ?? Data("[]".utf8)
        return httpResponse(200, "application/json", body)
    }

    private func monitorResponse() -> Data {
        let snaps = stateProvider?() ?? []
        let tc = snaps.first(where: { $0.ltcSource })?.tcTimecode
            ?? snaps.first(where: { $0.isMaster })?.tcTimecode
            ?? snaps.first(where: { $0.isPlaying })?.tcTimecode
            ?? snaps.compactMap(\.tcTimecode).first
            ?? "00:00:00:00"
        let payload: [String: Any] = [
            "tc": tc,
            "decks": snaps.map { s -> [String: Any] in
                [
                    "tag": s.tag,
                    "label": s.label,
                    "title": s.title,
                    "artist": s.artist,
                    "bpm": s.bpm,
                    "isPlaying": s.isPlaying,
                    "isMaster": s.isMaster,
                    "tcTimecode": s.tcTimecode ?? ""
                ]
            }
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return httpResponse(200, "application/json", body)
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
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>STAGE CONNECT</title>
<style>
:root{
  --bg:#09090e;--panel:#111118;--strip:#0d0d14;
  --border:#1e1e2e;--border2:#2a2a40;
  --accent:#f5a623;--green:#00e676;--cyan:#00bcd4;
  --red:#ff4060;--purple:#c084fc;--blue:#60a5fa;
  --text:#e8e8f0;--muted:#52526a;--dim:#2a2a3a;
  --font:'SF Mono','Consolas','Courier New',monospace;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;min-height:100vh}
.header{display:flex;align-items:center;gap:12px;padding:12px 20px;border-bottom:1px solid var(--border);background:var(--strip)}
.logo{font-size:13px;font-weight:800;letter-spacing:2px;color:var(--accent)}
.live{display:flex;align-items:center;gap:6px;font-size:10px;color:var(--green);letter-spacing:.6px;font-weight:600}
.dot{width:7px;height:7px;border-radius:50%;background:var(--green);animation:pulse 1.4s ease-in-out infinite}
.dot.off{background:var(--muted);animation:none}
@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.4;transform:scale(.85)}}
.status{margin-left:auto;font-size:10px;color:var(--muted);font-family:var(--font)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:12px;padding:16px}
.deck{background:var(--panel);border:1px solid var(--border);border-radius:8px;overflow:hidden;transition:border-color .2s}
.deck.playing{border-color:var(--accent)}
.deck.master{border-color:var(--green)}
.deck-strip{width:6px;flex-shrink:0;background:var(--dim)}
.deck-strip.playing{background:var(--accent)}
.deck-strip.master{background:var(--green)}
.deck-inner{display:flex;flex-direction:column;flex:1;padding:12px}
.deck-row{display:flex;gap:0}
.label{font-size:9px;font-weight:700;letter-spacing:1.2px;color:var(--muted);margin-bottom:5px}
.title{font-size:15px;font-weight:700;color:var(--green);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.1}
.deck.playing .title{color:var(--green)}
.artist{font-size:11px;color:var(--muted);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta-right{display:flex;flex-direction:column;align-items:flex-end;gap:4px;margin-left:auto;flex-shrink:0}
.bpm-block{text-align:right}
.bpm{font:700 28px/1 var(--font);color:var(--green);letter-spacing:-1px}
.bpm-label{font-size:8px;font-weight:700;color:var(--muted);letter-spacing:.8px}
.key-badge{font:700 11px var(--font);color:var(--purple);padding:1px 5px;background:rgba(192,132,252,.12);border-radius:3px}
.pitch{font:600 10px var(--font);color:var(--cyan)}
.badges{display:flex;gap:4px;margin-top:6px;flex-wrap:wrap}
.badge{font-size:8px;font-weight:800;letter-spacing:.8px;padding:2px 5px;border-radius:2px}
.badge.master{color:#000;background:var(--green)}
.badge.air{color:#000;background:var(--red)}
.badge.ltc{color:#000;background:var(--accent)}
.badge.play{color:var(--green);background:rgba(0,230,118,.12)}
.badge.pause{color:var(--muted);background:rgba(255,255,255,.06)}
.tc{font:700 11px var(--font);color:var(--accent);margin-top:4px;letter-spacing:.5px}
.beats{display:flex;gap:3px;margin:8px 0 4px}
.beat{height:16px;border-radius:2px;background:rgba(255,255,255,.06);flex:1;transition:background .06s}
.beat.b1.on{background:var(--green)}
.beat.on{background:var(--accent)}
.progress-wrap{position:relative;height:5px;background:rgba(255,255,255,.06);border-radius:2px;overflow:hidden}
.progress-fill{height:100%;border-radius:2px;background:var(--accent);transition:width .22s linear}
.times{display:flex;justify-content:space-between;margin-top:3px;font:10px var(--font);color:var(--muted)}
.time-el{color:var(--text)}
.no-decks{display:flex;align-items:center;justify-content:center;height:200px;color:var(--muted);font-size:13px}
footer{text-align:center;padding:16px;font-size:10px;color:var(--dim);letter-spacing:.4px}
</style>
</head>
<body>
<div class="header">
  <div class="logo">STAGE CONNECT</div>
  <div class="live"><div class="dot" id="dot"></div><span id="liveLabel">CONECTANDO...</span></div>
  <div class="status" id="status">--</div>
</div>
<div class="grid" id="g"><div class="no-decks">Conectando al servidor...</div></div>
<footer>entikrecords.com</footer>
<script>
const fmt=(s,full)=>{
  if(s==null)return full?'--:--:--':'--:--';
  const h=Math.floor(s/3600),m=Math.floor((s%3600)/60),ss=Math.floor(s%60),cs=Math.floor((s%1)*100);
  if(full)return[h,m,ss].map(n=>String(n).padStart(2,'0')).join(':');
  return String(m).padStart(2,'0')+':'+String(ss).padStart(2,'0');
};
const fmtRem=(e,d)=>{if(e==null||d==null)return'';const r=d-e;return r>0?'-'+fmt(r):'00:00'};
const pct=x=>x!=null?(x*100).toFixed(1)+'%':null;

let evtSource=null,retryT=null,lastUpdate=0;

function render(decks){
  lastUpdate=Date.now();
  document.getElementById('dot').className='dot';
  document.getElementById('liveLabel').textContent='EN VIVO';
  document.getElementById('status').textContent=
    new Date().toLocaleTimeString('es',{hour12:false})+' · '+decks.length+' deck'+(decks.length!==1?'s':'');
  const g=document.getElementById('g');
  if(!decks.length){g.innerHTML='<div class="no-decks">Sin decks activos</div>';return}
  g.innerHTML=decks.map(d=>{
    const playing=d.isPlaying, master=d.isMaster;
    const pctVal=d.progress!=null?d.progress*100:null;
    const beats=[1,2,3,4].map(i=>`<div class="beat${i===1?' b1':''}${d.beatInBar===i?' on':''}"></div>`).join('');
    const badges=[
      master?'<span class="badge master">MASTER</span>':'',
      d.isOnAir?'<span class="badge air">ON AIR</span>':'',
      d.ltcSource?'<span class="badge ltc">LTC</span>':'',
      playing?'<span class="badge play">PLAY</span>':'<span class="badge pause">PAUSE</span>',
    ].join('');
    const tc=d.tcTimecode?`<div class="tc">${d.tcTimecode}</div>`:'';
    const key=d.key?`<div class="key-badge">${d.key}</div>`:'';
    const pitch=d.pitchPct!=null&&Math.abs(d.pitchPct)>0.01?`<div class="pitch">${d.pitchPct>0?'+':''}${d.pitchPct.toFixed(2)}%</div>`:'';
    const prog=pctVal!=null?`
      <div class="progress-wrap"><div class="progress-fill" style="width:${pctVal.toFixed(1)}%"></div></div>
      <div class="times"><span class="time-el">${fmt(d.elapsed)}</span><span>${pctVal.toFixed(0)}%</span><span>${fmtRem(d.elapsed,d.duration)}</span></div>`:'';
    return`<div class="deck${playing?' playing':''}${master?' master':''}">
      <div class="deck-row">
        <div class="deck-strip${playing?' playing':''}${master?' master':''}"></div>
        <div class="deck-inner">
          <div class="label">${d.label.toUpperCase()}</div>
          <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:8px">
            <div style="min-width:0;flex:1">
              <div class="title">${playing?escHtml(d.title||'—'):'SIN PISTA'}</div>
              <div class="artist">${escHtml(d.artist)}</div>
              <div class="badges">${badges}</div>
              ${tc}
            </div>
            <div class="meta-right">
              <div class="bpm-block"><div class="bpm">${d.bpm>0?d.bpm.toFixed(2):'---.--'}</div><div class="bpm-label">BPM</div></div>
              ${key}${pitch}
            </div>
          </div>
          <div class="beats">${beats}</div>
          ${prog}
        </div>
      </div>
    </div>`;
  }).join('');
}

function escHtml(s){return(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}

function connect(){
  if(evtSource){evtSource.close();evtSource=null}
  evtSource=new EventSource('/events');
  evtSource.onmessage=e=>{try{render(JSON.parse(e.data))}catch(_){}};
  evtSource.onerror=()=>{
    document.getElementById('dot').className='dot off';
    document.getElementById('liveLabel').textContent='RECONECTANDO...';
    evtSource.close();evtSource=null;
    clearTimeout(retryT);retryT=setTimeout(connect,2000);
  };
}

connect();
// fallback poll si SSE falla
setInterval(()=>{if(Date.now()-lastUpdate>5000&&!evtSource)connect()},3000);
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
function paint(decks){
  const master=decks.find(d=>d.isMaster)||decks.find(d=>d.isPlaying)||decks[0];
  const tc=(master&&master.tcTimecode)||(decks.find(d=>d.tcTimecode)||{}).tcTimecode||'00:00:00:00';
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
