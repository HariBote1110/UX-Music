import SwiftUI

@main
struct UXMusicMobileApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    _ = model.applyPairingURL(url)
                }
        }
    }
}
