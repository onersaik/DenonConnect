import SwiftUI

struct RemoteDeck: Identifiable, Equatable {
    var id: String { label + "|" + title }
    var tag: String
    var label: String
    var title: String
    var artist: String
    var bpm: Double
    var isPlaying: Bool
    var tc: String
}

final class MonitorClient: ObservableObject {
    @Published var host: String = UserDefaults.standard.string(forKey: "sc.monitor.host") ?? "" {
        didSet { UserDefaults.standard.set(host, forKey: "sc.monitor.host") }
    }
    @Published var port: String = UserDefaults.standard.string(forKey: "sc.monitor.port") ?? "8080" {
        didSet { UserDefaults.standard.set(port, forKey: "sc.monitor.port") }
    }
    @Published var tc: String = "00:00:00:00"
    @Published var decks: [RemoteDeck] = []
    @Published var status: String = "Sin Mac"
    @Published var mini: Bool = UserDefaults.standard.bool(forKey: "sc.monitor.mini") {
        didSet { UserDefaults.standard.set(mini, forKey: "sc.monitor.mini") }
    }

    private var timer: Timer?
    private var task: URLSessionWebSocketTask?

    func start() {
        stop()
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        connectWS()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private var baseURL: URL? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, let p = UInt16(port), p > 0 else { return nil }
        return URL(string: "http://\(h):\(p)")
    }

    private func poll() {
        guard let root = baseURL else {
            status = "Pon la IP del Mac y el puerto del web (CONFIG → Web)"
            return
        }
        let url = root.appendingPathComponent("monitor")
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                self?.applyHTTP(data: data, resp: resp, err: err)
            }
        }.resume()
    }

    private func applyHTTP(data: Data?, resp: URLResponse?, err: Error?) {
        if let err {
            status = "No llega al Mac: \(err.localizedDescription)"
            return
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            status = "El Mac no responde /monitor — enciende Web en CONFIG"
            return
        }
        if let t = json["tc"] as? String, !t.isEmpty { tc = t }
        if let arr = json["decks"] as? [[String: Any]] {
            decks = arr.map { d in
                RemoteDeck(
                    tag: d["tag"] as? String ?? "",
                    label: d["label"] as? String ?? "",
                    title: d["title"] as? String ?? "",
                    artist: d["artist"] as? String ?? "",
                    bpm: (d["bpm"] as? NSNumber)?.doubleValue ?? 0,
                    isPlaying: d["isPlaying"] as? Bool ?? false,
                    tc: d["tcTimecode"] as? String ?? ""
                )
            }
        }
        status = decks.isEmpty ? "Mac conectado — sin pista" : "Mac \(host):\(port)"
    }

    private func connectWS() {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, let p = UInt16(port), p > 0,
              let url = URL(string: "ws://\(h):\(p)/ws") else { return }
        task?.cancel(with: .goingAway, reason: nil)
        let ws = URLSession.shared.webSocketTask(with: url)
        task = ws
        ws.resume()
        listenWS(ws)
    }

    private func listenWS(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            if case .success(let msg) = result {
                if case .string(let text) = msg, let data = text.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    DispatchQueue.main.async {
                        self?.applyWS(arr)
                    }
                }
            }
            self?.listenWS(ws)
        }
    }

    private func applyWS(_ arr: [[String: Any]]) {
        decks = arr.map { d in
            RemoteDeck(
                tag: d["tag"] as? String ?? "",
                label: d["label"] as? String ?? "",
                title: d["title"] as? String ?? "",
                artist: d["artist"] as? String ?? "",
                bpm: (d["bpm"] as? NSNumber)?.doubleValue ?? 0,
                isPlaying: d["isPlaying"] as? Bool ?? false,
                tc: d["tcTimecode"] as? String ?? ""
            )
        }
        if let t = decks.first(where: { !$0.tc.isEmpty })?.tc { tc = t }
    }
}

struct MonitorRootView: View {
    @StateObject private var client = MonitorClient()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                chrome
                if client.mini { miniBody } else { tcBody }
                HStack {
                    Text("entikrecords.com")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .foregroundColor(.white.opacity(0.28))
                    Spacer()
                    Text(client.status)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .onAppear { client.start() }
        .onDisappear { client.stop() }
    }

    private var chrome: some View {
        VStack(spacing: 8) {
            HStack {
                Text("MONITOR")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.6)
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
                Picker("", selection: $client.mini) {
                    Text("TC + decks").tag(false)
                    Text("Mini").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            HStack(spacing: 8) {
                TextField("IP del Mac", text: $client.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.system(size: 14, design: .monospaced))
                    .padding(8)
                    .background(Color.white.opacity(0.06))
                TextField("Puerto", text: $client.port)
                    .keyboardType(.numberPad)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(width: 72)
                    .padding(8)
                    .background(Color.white.opacity(0.06))
                Button("Conectar") { client.start() }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 1, green: 0.48, blue: 0.09))
            }
        }
        .padding(12)
    }

    private var tcBody: some View {
        VStack(spacing: 12) {
            Text("SMPTE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundColor(.white.opacity(0.35))
            Text(client.tc.isEmpty ? "00:00:00:00" : client.tc)
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.38, green: 1, blue: 0.48))
                .minimumScaleFactor(0.35)
                .lineLimit(1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(client.decks) { d in row(d, compact: false) }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var miniBody: some View {
        VStack(spacing: 8) {
            Text(client.tc.isEmpty ? "00:00:00:00" : client.tc)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.38, green: 1, blue: 0.48))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(client.decks) { d in row(d, compact: true) }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func row(_ d: RemoteDeck, compact: Bool) -> some View {
        HStack(spacing: 10) {
            Text(d.tag.isEmpty ? d.label : d.tag)
                .font(.system(size: compact ? 12 : 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: compact ? 56 : 76, alignment: .leading)
            Text(d.isPlaying ? "PLAY" : "STOP")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(d.isPlaying ? Color(red: 0.38, green: 1, blue: 0.48) : .white.opacity(0.3))
                .frame(width: 40, alignment: .leading)
            Text(d.title.isEmpty ? "SIN PISTA" : d.title)
                .font(.system(size: compact ? 13 : 16, weight: .semibold))
                .foregroundColor(d.title.isEmpty ? .white.opacity(0.3) : Color(red: 0.38, green: 1, blue: 0.48))
                .lineLimit(1)
            Spacer()
            Text(d.bpm > 0 ? String(format: "%.2f", d.bpm) : "---.--")
                .font(.system(size: compact ? 14 : 20, weight: .bold, design: .monospaced))
                .foregroundColor(d.bpm > 0 ? Color(red: 0.38, green: 1, blue: 0.48) : .white.opacity(0.2))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 6 : 10)
        .background(Color(white: 0.04))
    }
}
