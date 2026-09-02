// SC6000ConnectApp.swift
// Punto de entrada de la app SwiftUI.

import SwiftUI
import StageLinqKit

@main
struct SC6000ConnectApp: App {
    @StateObject private var manager = StageLinqManager()
    @StateObject private var proDJLink = ProDJLinkManager()
    @StateObject private var outputs = OutputController()
    @StateObject private var artwork = ArtworkFetcher()
    @StateObject private var testLink = TestLinkReceiver()
    @StateObject private var license = LicenseStore()
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
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
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
        .windowResizability(.contentSize)
        .defaultSize(CGSize(width: 1280, height: 820))
        .commands {
            CommandGroup(replacing: .newItem) {} // sin "Nueva ventana": esta app es de instancia única
        }
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        manager.start()
        proDJLink.start()
        testLink.start()
        outputs.attach(stageLinq: manager, proDJLink: proDJLink, testLink: testLink)
    }

    private func stopServices() {
        guard servicesStarted else { return }
        servicesStarted = false
        outputs.shutdown()
        manager.stop()
        proDJLink.stop()
        testLink.stop()
    }
}
