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

    var body: some Scene {
        WindowGroup("STAGE CONNECT") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(proDJLink)
                .environmentObject(outputs)
                .environmentObject(artwork)
                .environmentObject(testLink)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear {
                    manager.start()
                    proDJLink.start()
                    testLink.start()
                    outputs.attach(stageLinq: manager, proDJLink: proDJLink, testLink: testLink)
                }
                .onDisappear {
                    outputs.shutdown()
                    manager.stop()
                    proDJLink.stop()
                    testLink.stop()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(CGSize(width: 1280, height: 820))
        .commands {
            CommandGroup(replacing: .newItem) {} // sin "Nueva ventana": esta app es de instancia única
        }
    }
}
