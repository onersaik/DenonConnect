// SC6000ConnectApp.swift
// Punto de entrada de la app SwiftUI.

import SwiftUI
import StageLinqKit

@main
struct SC6000ConnectApp: App {
    @StateObject private var manager = StageLinqManager()

    var body: some Scene {
        WindowGroup("SC6000 Connect") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear { manager.start() }
                .onDisappear { manager.stop() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // sin "Nueva ventana": esta app es de instancia única
        }
    }
}
