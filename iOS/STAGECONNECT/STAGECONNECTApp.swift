// STAGE CONNECT para iPad — monitor de decks (StageLinq + Pro DJ Link).

import SwiftUI
import StageLinqKit

@main
struct STAGECONNECTApp: App {
    @StateObject private var manager = StageLinqManager()
    @StateObject private var proDJLink = ProDJLinkManager()
    @StateObject private var testLink = TestLinkReceiver()
    @StateObject private var license = LicenseStore()

    var body: some Scene {
        WindowGroup {
            PadRootView()
                .environmentObject(manager)
                .environmentObject(proDJLink)
                .environmentObject(testLink)
                .environmentObject(testLink.playback)
                .environmentObject(license)
                .preferredColorScheme(.dark)
                .onAppear {
                    license.refresh()
                    // LAN siempre: el overlay de licencia no apaga descubrimiento.
                    manager.start()
                    proDJLink.start()
                    testLink.start()
                }
                .onChange(of: license.isUnlocked) { unlocked in
                    // Sin unlock solo hay ActivationView; Dual/SMPTE/UDP siguen.
                    if unlocked {
                        manager.start()
                        proDJLink.start()
                        testLink.start()
                    }
                }
        }
    }
}
