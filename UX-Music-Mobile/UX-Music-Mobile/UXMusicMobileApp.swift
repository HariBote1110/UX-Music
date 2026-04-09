import SwiftUI
import UIKit

@main
struct UXMusicMobileApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.beginReceivingRemoteControlEvents()
                }
                .onOpenURL { url in
                    _ = model.applyPairingURL(url)
                }
        }
    }
}
