import AVFoundation
import AVKit
import SwiftUI
import UIKit

// =====================================================================
// FairPlay Streaming (FPS) 客户端实现
//
// 播放流程：
//   1. AVPlayer 播放 HLS(m3u8)，遇到 #EXT-X-KEY ... URI="skd://xxx" 的加密分片
//   2. AVContentKeySession 把密钥请求交给我们（本文件）
//   3. 我们向自己的服务器取 FairPlay 证书
//   4. 用证书 + assetId 生成 SPC（Server Playback Context）
//   5. 把 SPC POST 给许可证服务器，换回 CKC（Content Key Context）
//   6. 把 CKC 交给 AVPlayer → 解密播放
//
// 注意：第 3、5 步需要服务端配合（见《服务端FairPlay实施指南.md》）。
// =====================================================================

final class FairPlayKeyLoader: NSObject {

    struct Config: Equatable {
        /// 取 FairPlay 证书的地址，例如 https://your-server/fps/cert
        var certificateURL: String = ""
        /// 换取许可证(CKC)的地址，例如 https://your-server/fps/license
        var licenseURL: String = ""
        /// 可选：固定 assetId（留空则从 skd:// 里取）
        var assetID: String = ""
        /// 可选：自定义请求头（例如 Authorization 或 cookie）
        var authorization: String = ""

        var isConfigured: Bool {
            !certificateURL.isEmpty && !licenseURL.isEmpty
        }
    }

    private let config: Config

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - 网络

    private func fetchCertificate(completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: config.certificateURL) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if !config.authorization.isEmpty {
            req.setValue(config.authorization, forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            completion(data)
        }.resume()
    }

    private func requestLicense(spc: Data, assetID: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: config.licenseURL) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(assetID, forHTTPHeaderField: "X-Asset-Id")
        if !config.authorization.isEmpty {
            req.setValue(config.authorization, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = spc
        URLSession.shared.dataTask(with: req) { data, _, _ in
            completion(data)
        }.resume()
    }

    // MARK: - assetId

    private func assetID(from identifier: Any?) -> String {
        if !config.assetID.isEmpty { return config.assetID }
        if let s = identifier as? String {
            if let r = s.range(of: "skd://") {
                return String(s[r.upperBound...])
            }
            return s
        }
        if let u = identifier as? URL {
            if let host = u.host, !host.isEmpty { return host }
            return u.absoluteString
        }
        return ""
    }

    private func fail(_ request: AVContentKeyRequest, _ message: String) {
        let err = NSError(domain: "FairPlay", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        request.processContentKeyResponseError(err)
    }
}

extension FairPlayKeyLoader: AVContentKeySessionDelegate {

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession,
                           didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession,
                           shouldRetry keyRequest: AVContentKeyRequest,
                           reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        return true
    }

    private func handle(_ keyRequest: AVContentKeyRequest) {
        guard config.isConfigured else {
            fail(keyRequest, "尚未配置 FairPlay 证书地址与许可证地址")
            return
        }

        let id = assetID(from: keyRequest.identifier)

        fetchCertificate { [weak self] cert in
            guard let self = self else { return }
            guard let cert = cert, !cert.isEmpty else {
                DispatchQueue.main.async { self.fail(keyRequest, "无法从服务器获取 FairPlay 证书") }
                return
            }

            do {
                // 1) 生成 SPC
                let spc = try keyRequest.makeStreamingContentKeyRequestData(
                    forApp: cert,
                    contentIdentifier: id.data(using: .utf8),
                    options: [AVContentKeyRequestProtocolVersionsKey: [1]]
                )

                // 2) 用 SPC 换 CKC
                self.requestLicense(spc: spc, assetID: id) { ckc in
                    DispatchQueue.main.async {
                        guard let ckc = ckc, !ckc.isEmpty else {
                            self.fail(keyRequest, "许可证服务器未返回密钥（CKC 为空）")
                            return
                        }
                        keyRequest.processContentKeyResponse(AVContentKeyResponse(data: ckc))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.fail(keyRequest, "生成 SPC 失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

// =====================================================================
// 原生播放器（AVPlayer + FairPlay）
// =====================================================================

final class FairPlayPlayerController: UIViewController {

    private let streamURL: URL
    private let config: FairPlayKeyLoader.Config

    private var player: AVPlayer?
    private var keySession: AVContentKeySession?
    private var keyLoader: FairPlayKeyLoader?
    private var playerViewController: AVPlayerViewController?
    private var statusLabel: UILabel?

    init(streamURL: URL, config: FairPlayKeyLoader.Config) {
        self.streamURL = streamURL
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        startPlayback()
    }

    private func startPlayback() {
        let loader = FairPlayKeyLoader(config: config)
        keyLoader = loader

        let asset = AVURLAsset(url: streamURL)

        // 只有配置了 FairPlay 服务器时才挂密钥会话；
        // 否则按普通 HLS 播放（明文流也能播）。
        if config.isConfigured {
            let session = AVContentKeySession(keySystem: .fairPlayStreaming)
            session.setDelegate(loader, queue: .main)
            session.addContentKeyRecipient(asset)
            keySession = session
        }

        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p

        let vc = AVPlayerViewController()
        vc.player = p
        vc.allowsPictureInPicturePlayback = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.showsPlaybackControls = true
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        playerViewController = vc

        // 状态提示
        let label = UILabel()
        label.text = "正在加载…\n\(streamURL.absoluteString)"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80)
        ])
        statusLabel = label

        NotificationCenter.default.addObserver(self,
                                              selector: #selector(failed(_:)),
                                              name: .AVPlayerItemFailedToPlayToEndTime,
                                              object: item)

        observeStatus(item)
        p.play()
    }

    private func observeStatus(_ item: AVPlayerItem) {
        // 简单轮询状态，避免 KVO 样板代码
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self, weak item] timer in
            guard let self = self, let item = item else { timer.invalidate(); return }
            switch item.status {
            case .readyToPlay:
                self.statusLabel?.text = self.config.isConfigured
                    ? "FairPlay 已就绪 · 正在播放"
                    : "明文 HLS · 正在播放"
            case .failed:
                self.statusLabel?.text = "播放失败：\(item.error?.localizedDescription ?? "未知错误")"
                timer.invalidate()
            default:
                break
            }
        }
    }

    @objc private func failed(_ note: Notification) {
        let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        statusLabel?.text = "播放中断：\(err?.localizedDescription ?? "未知错误")"
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
    }
}

// =====================================================================
// SwiftUI 包装
// =====================================================================

struct FairPlayPlayerView: UIViewControllerRepresentable {
    let streamURL: URL
    let config: FairPlayKeyLoader.Config

    func makeUIViewController(context: Context) -> FairPlayPlayerController {
        FairPlayPlayerController(streamURL: streamURL, config: config)
    }

    func updateUIViewController(_ uiViewController: FairPlayPlayerController, context: Context) {}
}
