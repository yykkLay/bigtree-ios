import AVFoundation

/// 配置音频会话，让视频可以在后台继续播放（对应安卓端的 PlaybackService）。
enum AudioSetup {
    static func configure() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback,
                                    mode: .moviePlayback,
                                    options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            // 忽略：配置失败不影响前台播放
        }
    }
}
