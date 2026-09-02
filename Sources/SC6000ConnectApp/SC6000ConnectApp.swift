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

    var body: some Scene {
        WindowGroup("SC6000 Connect") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(proDJLink)
                .environmentObject(outputs)
                .environmentObject(artwork)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear {
                    manager.start()
                    proDJLink.start()
                    outputs.attach(stageLinq: manager, proDJLink: proDJLink)
                }
                .onDisappear {
                    manager.stop()
                    proDJLink.stop()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // sin "Nueva ventana": esta app es de instancia única
        }
    }
}
