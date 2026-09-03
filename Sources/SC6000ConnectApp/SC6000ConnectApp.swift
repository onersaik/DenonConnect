// SC6000ConnectApp.swift
// Punto de entrada de la app SwiftUI.

import SwiftUI
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
    @State private var servicesStarted = false

    var body: some Scene {
        WindowGroup("STAGE CONNECT") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(proDJLink)
                .environmentObject(outputs)
                .environmentObject(artwork)
                .environmentObject(testLink)
                .environmentObject(license)
                .environmentObject(mapping)
                .environmentObject(software)
                .environmentObject(labels)
                .environmentObject(tracklist)
                .environmentObject(theme)
                .environmentObject(localization)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(theme.isDark ? .dark : .light)
                .onAppear {
                    license.refresh()
                    if license.isUnlocked { startServices() }
                }
                .onChange(of: license.isUnlocked) { unlocked in
                    if unlocked { startServices() } else { stopServices() }
                }
                .onDisappear {
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
                .environmentObject(software)
                .environmentObject(labels)
                .environmentObject(mapping)
                .environmentObject(artwork)
                .environmentObject(theme)
                .environmentObject(localization)
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
        manager.start()
        proDJLink.start()
        testLink.start()
        outputs.attach(stageLinq: manager, proDJLink: proDJLink, testLink: testLink, software: software, tracklist: tracklist)
        mapping.attach(outputs: outputs)
        mapping.start()
        software.start()
    }

    private func stopServices() {
        guard servicesStarted else { return }
        servicesStarted = false
        mapping.stop()
        outputs.shutdown()
        software.stop()
        manager.stop()
        proDJLink.stop()
        testLink.stop()
    }
}
