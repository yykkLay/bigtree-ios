import SwiftUI
import WebKit
import UIKit

enum ActiveSheet: String, Identifiable {
    case scanner
    case address
    case streams
    case fairplay
    var id: String { rawValue }
}

struct ContentView: View {

    private struct TabItem: Identifiable {
        let id: Int
        let title: String
        let icon: String
        let url: String
    }

    private let tabItems: [TabItem] = [
        TabItem(id: 0, title: "首页", icon: "house.fill",           url: "https://ibutv.com/"),
        TabItem(id: 1, title: "片库", icon: "square.grid.2x2.fill", url: "https://ibutv.com/#/pianku"),
        TabItem(id: 2, title: "种子", icon: "link",                 url: "https://ibutv.com/#/torrent"),
        TabItem(id: 3, title: "音乐", icon: "music.note",           url: "https://ibutv.com/#/music"),
        TabItem(id: 4, title: "搜索", icon: "magnifyingglass",      url: "https://ibutv.com/#/search")
    ]

    @State private var uaMode: UAMode = .plugin
    @State private var fakeApp = false

    @State private var startURL = URL(string: "https://ibutv.com/")!
    @State private var reloadKey = UUID()

    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var pageTitle = "BigTree"
    @State private var webView: WKWebView?

    @State private var currentTab = 0
    @State private var activeSheet: ActiveSheet?
    @State private var addressText = ""

    // 捕获到的视频流地址（m3u8 / skd）
    @State private var capturedStreams: [String] = []
    @State private var manualStream = ""

    // 界面偏好
    @AppStorage("hide_close_btn") private var hideCloseBtn = true

    // FairPlay 服务器配置
    @AppStorage("fp_cert")    private var fpCert = ""
    @AppStorage("fp_license") private var fpLicense = ""
    @AppStorage("fp_asset")   private var fpAsset = ""
    @AppStorage("fp_auth")    private var fpAuth = ""

    // 原生播放
    @State private var playingURL: URL?
    @State private var showPlayer = false

    private var fpConfig: FairPlayKeyLoader.Config {
        FairPlayKeyLoader.Config(certificateURL: fpCert,
                                 licenseURL: fpLicense,
                                 assetID: fpAsset,
                                 authorization: fpAuth)
    }

    var body: some View {
        VStack(spacing: 0) {

            topBar
            Divider()

            ZStack(alignment: .top) {
                WebView(uaMode: uaMode,
                        fakeApp: fakeApp,
                        startURL: startURL,
                        canGoBack: $canGoBack,
                        canGoForward: $canGoForward,
                        isLoading: $isLoading,
                        pageTitle: $pageTitle,
                        hideCloseButton: hideCloseBtn,
                        onStream: { url in
                            if !capturedStreams.contains(url) {
                                capturedStreams.append(url)
                            }
                        }) { wv in
                    webView = wv
                }
                .id(reloadKey)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }

            Divider()
            tabBar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(item: $activeSheet) { item in
            switch item {
            case .scanner:
                ScannerView(onCode: { code in
                    activeSheet = nil
                    openScanned(code)
                }, onClose: {
                    activeSheet = nil
                })
                .ignoresSafeArea()
            case .address:
                addressSheet
            case .streams:
                streamsSheet
            case .fairplay:
                fairplaySheet
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            Group {
                if let url = playingURL {
                    FairPlayPlayerView(streamURL: url, config: fpConfig)
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // 顶部工具条
    // ---------------------------------------------------------------
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { webView?.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
            }
            .disabled(!canGoBack)

            Button { webView?.goForward() } label: {
                Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold))
            }
            .disabled(!canGoForward)

            Text(pageTitle.isEmpty ? "BigTree" : pageTitle)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { webView?.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .medium))
            }

            Menu {
                Button {
                    activeSheet = .streams
                } label: {
                    Label("原生播放（FairPlay）· 已捕获 \(capturedStreams.count) 条",
                          systemImage: "play.rectangle.on.rectangle")
                }

                Button {
                    activeSheet = .fairplay
                } label: {
                    Label(fpConfig.isConfigured ? "FairPlay 服务器：已配置"
                                                : "FairPlay 服务器：未配置",
                          systemImage: "lock.shield")
                }

                Divider()

                Button { activeSheet = .scanner } label: {
                    Label("扫码打开", systemImage: "qrcode.viewfinder")
                }

                Button {
                    addressText = webView?.url?.absoluteString ?? ""
                    activeSheet = .address
                } label: {
                    Label("输入地址", systemImage: "link.badge.plus")
                }

                Divider()

                Button { cycleUA() } label: {
                    Label("User-Agent：\(uaMode.label)（点击切换）", systemImage: "person.crop.circle")
                }

                Divider()

                Button {
                    hideCloseBtn.toggle()
                    reloadKeepingURL()
                } label: {
                    Label(hideCloseBtn ? "隐藏全屏退出按钮：开（双击画面退出）"
                                       : "隐藏全屏退出按钮：关",
                          systemImage: "xmark.circle")
                }

                Button { goHome() } label: {
                    Label("回到首页", systemImage: "house")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18, weight: .medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.10))
    }

    // ---------------------------------------------------------------
    // 底部栏目
    // ---------------------------------------------------------------
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(tabItems) { item in
                Button {
                    currentTab = item.id
                    startURL = URL(string: item.url)!
                    reloadKey = UUID()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.system(size: 17, weight: .medium))
                        Text(item.title).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(currentTab == item.id ? Color.blue : Color.gray)
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.gray.opacity(0.10))
    }

    // ---------------------------------------------------------------
    // 输入地址
    // ---------------------------------------------------------------
    private var addressSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("网址")) {
                    TextField("https://", text: $addressText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }
                Section {
                    Button("打开") {
                        activeSheet = nil
                        openScanned(addressText)
                    }
                    Button("粘贴剪贴板内容") {
                        if let s = UIPasteboard.general.string { addressText = s }
                    }
                }
            }
            .navigationTitle("输入地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { activeSheet = nil }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // 原生播放（FairPlay）—— 选择要播放的视频流
    // ---------------------------------------------------------------
    private var streamsSheet: some View {
        NavigationView {
            List {
                Section(header: Text("手动输入视频流地址（.m3u8 或 skd://）")) {
                    TextField("https://….m3u8", text: $manualStream)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    Button("用原生播放器播放") {
                        play(manualStream)
                    }
                    Button("粘贴剪贴板内容") {
                        if let s = UIPasteboard.general.string { manualStream = s }
                    }
                }

                Section(header: Text("已捕获的视频流（\(capturedStreams.count)）")) {
                    if capturedStreams.isEmpty {
                        Text("还没有捕获到。请先在网页里点开一个视频，等它开始加载，再回来这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(capturedStreams, id: \.self) { s in
                            Button {
                                play(s)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s)
                                        .font(.system(size: 12))
                                        .lineLimit(2)
                                    Text(s.contains("skd://") ? "加密流（需要 FairPlay）" : "普通流")
                                        .font(.system(size: 10))
                                        .foregroundStyle(s.contains("skd://") ? Color.orange : Color.green)
                                }
                            }
                        }
                    }
                }

                if !fpConfig.isConfigured {
                    Section {
                        Text("提示：要播放加密流，需要先在「FairPlay 服务器」里填好证书地址和许可证地址。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("原生播放（FairPlay）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { activeSheet = nil }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { capturedStreams.removeAll() }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // FairPlay 服务器配置
    // ---------------------------------------------------------------
    private var fairplaySheet: some View {
        NavigationView {
            Form {
                Section(header: Text("密钥服务器")) {
                    TextField("证书地址 https://…/cert", text: $fpCert)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("许可证地址 https://…/license", text: $fpLicense)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }

                Section(header: Text("可选")) {
                    TextField("固定 assetId（留空则用 skd:// 里的）", text: $fpAsset)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Authorization 请求头（可留空）", text: $fpAuth)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Section {
                    Text("证书与许可证地址由你的服务端提供。服务端需要向苹果申请 FairPlay Streaming 证书，并用 KSM（或第三方 DRM 服务）生成 CKC。详见随附的实施指南。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("清空配置") {
                        fpCert = ""; fpLicense = ""; fpAsset = ""; fpAuth = ""
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("FairPlay 服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { activeSheet = nil }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // 动作
    // ---------------------------------------------------------------
    private func play(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var candidate = t
        if !candidate.lowercased().hasPrefix("http") && !candidate.lowercased().hasPrefix("skd://") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate) else { return }
        activeSheet = nil
        playingURL = url
        showPlayer = true
    }

    private func cycleUA() {
        let all = UAMode.allCases
        if let i = all.firstIndex(of: uaMode) {
            uaMode = all[(i + 1) % all.count]
        }
        reloadKeepingURL()
    }

    private func reloadKeepingURL() {
        if let cur = webView?.url, cur.absoluteString.hasPrefix("http") {
            startURL = cur
        }
        reloadKey = UUID()
    }

    private func goHome() {
        currentTab = 0
        startURL = URL(string: "https://ibutv.com/")!
        reloadKey = UUID()
    }

    private func openScanned(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var candidate = trimmed
        if !candidate.lowercased().hasPrefix("http") {
            candidate = "https://" + candidate
        }
        if let url = URL(string: candidate) {
            startURL = url
            reloadKey = UUID()
        }
    }
}

#Preview {
    ContentView()
}
