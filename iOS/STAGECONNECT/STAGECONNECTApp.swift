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
                .environmentObject(license)
                .preferredColorScheme(.dark)
                .onAppear {
                    license.refresh()
                    if license.isUnlocked {
                        manager.start()
                        proDJLink.start()
                        testLink.start()
                    }
                }
                .onChange(of: license.isUnlocked) { unlocked in
                    if unlocked {
                        manager.start(); proDJLink.start(); testLink.start()
                    } else {
                        manager.stop(); proDJLink.stop(); testLink.stop()
                    }
                }
        }
    }
}
