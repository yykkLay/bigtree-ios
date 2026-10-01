import SwiftUI
import WebKit

struct ContentView: View {
    @State private var uaMode: UAMode = .desktop
    @State private var fakeApp = false
    @State private var startURL = URL(string: "https://ibutv.com/")!
    @State private var reloadKey = UUID()

    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var pageTitle = "ibutv"
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
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
            toolbar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { webView?.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .medium))
            }
            .disabled(!canGoBack)

            Button { webView?.goForward() } label: {
                Image(systemName: "chevron.right").font(.system(size: 17, weight: .medium))
            }
            .disabled(!canGoForward)

            Button { webView?.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .medium))
            }

            Spacer(minLength: 4)

            Button {
                cycleUA()
            } label: {
                Text("UA·\(uaMode.label)")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(Color.blue)
                    .clipShape(Capsule())
            }

            Button {
                fakeApp.toggle()
                reloadKeepingURL()
            } label: {
                Text(fakeApp ? "App身份·开" : "App身份·关")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(fakeApp ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                    .foregroundStyle(fakeApp ? Color.green : Color.gray)
                    .clipShape(Capsule())
            }

            Spacer(minLength: 4)

            Button {
                startURL = URL(string: "https://ibutv.com/")!
                reloadKey = UUID()
            } label: {
                Image(systemName: "house").font(.system(size: 16, weight: .medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.gray.opacity(0.12))
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
}

#Preview {
    ContentView()
}
