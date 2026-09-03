// SC6000ConnectApp.swift
// Punto de entrada de la app SwiftUI.

import SwiftUI
import AppKit
import Darwin
import StageLinqKit

@main
struct SC6000ConnectApp: App {
    @StateObject private var manager    = StageLinqManager()
    @StateObject private var proDJLink  = ProDJLinkManager()
    @StateObject private var outputs    = OutputController()
    @StateObject private var artwork    = ArtworkFetcher()
    @StateObject private var testLink   = TestLinkReceiver()
    @StateObject private var license    = LicenseStore()
    @StateObject private var mapping    = MappingController()
    @StateObject private var software   = SoftwareDJManager()
    @StateObject private var labels     = DeckLabelStore()
    @StateObject private var tracklist  = TracklistStore()
    @StateObject private var theme      = ThemeStore()
    @StateObject private var localization = LocalizationStore()
    @StateObject private var updates    = AppUpdateStore()
    @State private var servicesStarted = false
    private let networkRecovery = NetworkRecoveryMonitor()

    /// Mantiene el flock de instancia única vivo hasta el exit del proceso.
    private static var instanceLockFD: Int32 = -1

    init() {
        // SO_REUSEADDR en :50000/:51337 permite 2ª copia; Darwin reparte UDP y
        // se pierden CDJ/SC6000. Una sola instancia Mac.
        Self.ensureSingleInstance()
    }

    var body: some Scene {
        WindowGroup("STAGE CONNECT") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(proDJLink)
                .environmentObject(outputs)
                .environmentObject(artwork)
                .environmentObject(testLink)
                .environmentObject(testLink.playback)
                .environmentObject(license)
                .environmentObject(mapping)
                .environmentObject(software)
                .environmentObject(labels)
                .environmentObject(tracklist)
                .environmentObject(theme)
                .environmentObject(localization)
                .environmentObject(updates)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(theme.isDark ? .dark : .light)
                .onAppear {
                    license.refresh()
                    // LAN siempre: Dual/SMPTE/descubrimiento no esperan a connectapp.entikmedia.com.
                    startServices()
                    // Latido opcional: sin red / NXDOMAIN no toca la cabina (ver LicenseStore).
                    license.verifyInBackground()
                    updates.checkForUpdates()
                }
                .onChange(of: license.isUnlocked) { unlocked in
                    // LAN / Dual / SMPTE / descubrimiento no dependen de la licencia.
                    // Sin unlock solo hay overlay ActivationView; no se apaga UDP.
                    if unlocked { startServices() }
                }
                // No onDisappear→stop: cerrar la ventana principal (Monitor/Setlist
                // siguen) mataba Dual/SMPTE/descubrimiento/TestLink. Solo al salir.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    stopServices()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(CGSize(width: 1280, height: 820))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("STAGE CONNECT Monitor", id: "sc-monitor") {
            MonitorWindowView()
                .environmentObject(manager)
                .environmentObject(proDJLink)
                .environmentObject(outputs)
                .environmentObject(testLink)
                .environmentObject(testLink.playback)
                .environmentObject(software)
                .environmentObject(labels)
                .environmentObject(mapping)
                .environmentObject(artwork)
                .environmentObject(theme)
                .environmentObject(localization)
                .environmentObject(tracklist)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(CGSize(width: 1440, height: 810))

        Window("STAGE CONNECT Setlist", id: "sc-tracklist") {
            TracklistWindowView()
                .environmentObject(tracklist)
                .environmentObject(outputs)
                .environmentObject(manager)
                .environmentObject(proDJLink)
                .environmentObject(testLink)
                .environmentObject(testLink.playback)
                .environmentObject(software)
                .environmentObject(theme)
                .environmentObject(localization)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(CGSize(width: 720, height: 860))
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        ProtocolLog.resetForLaunch()
        manager.start()
        proDJLink.start()
        testLink.start()
        outputs.attach(stageLinq: manager, proDJLink: proDJLink, testLink: testLink, software: software, tracklist: tracklist)
        mapping.attach(outputs: outputs)
        mapping.start()
        software.start()
        networkRecovery.start(stageLinq: manager, proDJLink: proDJLink, outputs: outputs)
        // Arranque: ráfaga HOWDY + keepalive por si el cable ya estaba.
        manager.kickNetworkRecovery(reason: "arranque")
        proDJLink.kickNetworkRecovery(reason: "arranque")
    }

    private func stopServices() {
        guard servicesStarted else { return }
        servicesStarted = false
        networkRecovery.stop()
        mapping.stop()
        outputs.shutdown()
        software.stop()
        manager.stop()
        proDJLink.stop()
        testLink.stop()
    }

    private static func ensureSingleInstance() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.entikrecords.stageconnect"
        let me = ProcessInfo.processInfo.processIdentifier
        let activateOpts: NSApplication.ActivationOptions = [
            .activateAllWindows, .activateIgnoringOtherApps,
        ]
        let peers: () -> [NSRunningApplication] = {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me && !$0.isTerminated }
        }

        // Ya hay otra copia visible → enfocarla y salir (no tocar UDP).
        if let primary = peers().first {
            primary.activate(options: activateOpts)
            exit(0)
        }
        // flock: carrera al abrir 2 copias a la vez (peers() aún vacío).
        if !acquireInstanceLock() {
            peers().first?.activate(options: activateOpts)
            exit(0)
        }
    }

    private static func acquireInstanceLock() -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("STAGE CONNECT", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("instance.lock").path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }
}
