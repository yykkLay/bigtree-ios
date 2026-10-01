import SwiftUI

@main
struct BigtreeApp: App {
    init() {
        // 让视频可以在后台继续播放（对应安卓端的 PlaybackService）
        AudioSetup.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
