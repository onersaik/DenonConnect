// STAGE CONNECT Monitor — iPhone/iPad.
// No habla StageLinq ni Pro DJ Link. Lee el Mac: http://IP:puerto/monitor
// y ws://IP:puerto/ws (servidor web de STAGE CONNECT).

import SwiftUI

@main
struct STAGECONNECTMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            MonitorRootView()
                .preferredColorScheme(.dark)
        }
    }
}
