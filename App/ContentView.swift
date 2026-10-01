import SwiftUI
import WebKit
import UIKit

struct ContentView: View {

    private struct TabItem: Identifiable {
        let id: Int
        let title: String
        let icon: String
        let url: String
    }

    // 对应 ibutv 网站的栏目（我从网站前端代码里读到的路由）
    private let tabItems: [TabItem] = [
        TabItem(id: 0, title: "首页", icon: "house.fill",            url: "https://ibutv.com/"),
        TabItem(id: 1, title: "片库", icon: "square.grid.2x2.fill",  url: "https://ibutv.com/#/pianku"),
        TabItem(id: 2, title: "种子", icon: "link",                  url: "https://ibutv.com/#/torrent"),
        TabItem(id: 3, title: "音乐", icon: "music.note",            url: "https://ibutv.com/#/music"),
        TabItem(id: 4, title: "搜索", icon: "magnifyingglass",       url: "https://ibutv.com/#/search")
    ]

    @State private var uaMode: UAMode = .desktop
    @State private var fakeApp = false

    @State private var startURL = URL(string: "https://ibutv.com/")!
    @State private var reloadKey = UUID()

    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var pageTitle = "BigTree"
    @State private var webView: WKWebView?

    @State private var currentTab = 0
    @State private var showScanner = false
    @State private var showAddress = false
    @State private var addressText = ""

    var body: some View {
        VStack(spacing: 0) {

            // 顶部工具条
            topBar
            Divider()

            // 网页主体
            ZStack(alignment: .top) {
                WebView(uaMode: uaMode,
                        fakeApp: fakeApp,
                        startURL: startURL,
                        canGoBack: $canGoBack,
                        canGoForward: $canGoForward,
                        isLoading: $isLoading,
                        pageTitle: $pageTitle) { wv in
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

            // 底部栏目
            tabBar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(nil)
        .sheet(isPresented: $showScanner) {
            ScannerView(onCode: { code in
                showScanner = false
                openScanned(code)
            }, onClose: {
                showScanner = false
            })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showAddress) {
            addressSheet
        }
        .onOpenURL { url in
            webView?.load(URLRequest(url: url))
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
                    showScanner = true
                } label: {
                    Label("扫码打开", systemImage: "qrcode.viewfinder")
                }

                Button {
                    addressText = webView?.url?.absoluteString ?? ""
                    showAddress = true
                } label: {
                    Label("输入地址", systemImage: "link.badge.plus")
                }

                Divider()

                Button {
                    cycleUA()
                } label: {
                    Label("User-Agent：\(uaMode.label)（点击切换）", systemImage: "person.crop.circle")
                }

                Button {
                    fakeApp.toggle()
                    reloadKeepingURL()
                } label: {
                    Label(fakeApp ? "App 身份：开" : "App 身份：关", systemImage: "app.badge")
                }

                Divider()

                Button {
                    goHome()
                } label: {
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
                        Image(systemName: item.icon)
                            .font(.system(size: 17, weight: .medium))
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
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
                        showAddress = false
                        openScanned(addressText)
                    }
                    Button("粘贴并打开") {
                        if let s = UIPasteboard.general.string {
                            addressText = s
                        }
                    }
                }
            }
            .navigationTitle("输入地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddress = false }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // 动作
    // ---------------------------------------------------------------
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
