import SwiftUI
import WebKit

/// User-Agent 模式。
/// 关键点：官方安卓 App 用的就是「桌面 Chrome」的 UA（我从 bigtree.apk 里挖出来的），
/// 借它让 ibutv 认为访问者是桌面浏览器，而不是"被禁用的手机"。
enum UAMode: String, CaseIterable, Identifiable {
    case desktop
    case android
    case iosDefault

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktop:    return "桌面"
        case .android:    return "安卓"
        case .iosDefault: return "iOS"
        }
    }

    /// 返回 nil 表示用系统默认 UA
    var userAgent: String? {
        switch self {
        case .desktop:
            // ★ 与 bigtree.apk 中硬编码的 UA 完全一致
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        case .android:
            return "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
        case .iosDefault:
            return nil
        }
    }
}

struct WebView: UIViewRepresentable {
    var uaMode: UAMode
    var fakeApp: Bool
    var startURL: URL

    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var pageTitle: String

    var onWebView: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(iOS 15.4, *) {
            config.preferences.isElementFullscreenEnabled = true
        }

        let script = WKUserScript(source: WebView.injectedJS(fakeApp: fakeApp),
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        config.userContentController.addUserScript(script)

        let wv = WKWebView(frame: .zero, configuration: config)
        if let ua = uaMode.userAgent {
            wv.customUserAgent = ua
        }
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.load(URLRequest(url: startURL))

        let handler = onWebView
        DispatchQueue.main.async { handler(wv) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 状态同步由 Coordinator 的代理回调负责
    }

    /// 注入到网页的脚本：
    /// 1) 补发 xstree 插件的「已就绪」信号（网页最多等 8 秒）
    /// 2) 给官方 App 才有的原生桥提供存根，避免网页调用报错
    /// 3) 可选：伪造 window.Android，让 ibutv 把本 App 当成官方安卓客户端
    static func injectedJS(fakeApp: Bool) -> String {
        var js = "(function () {\n"
        js += "try { window.__rulesReady = true; } catch (e) {}\n"

        js += "try { setInterval(function () { try { window.postMessage({ type: 'RULES_READY' }, location.origin); } catch (e) {} }, 1000); } catch (e) {}\n"

        js += "try {\n"
        js += "if (typeof window.__bigtreeRemoteCommand !== 'function') { window.__bigtreeRemoteCommand = function () { return 0; }; }\n"
        js += "if (typeof window.__exitPlayerFullscreen !== 'function') { window.__exitPlayerFullscreen = function () { try { var el = document.fullscreenElement || document.webkitFullscreenElement; if (el) { (document.exitFullscreen || document.webkitExitFullscreen).call(document); return 1; } } catch (e) {} return 0; }; }\n"
        js += "window.__urlWatcher = true;\n"
        js += "} catch (e) {}\n"

        if fakeApp {
            js += "try { if (!window.Android) { window.Android = { getVersion: function () { return '1.0.8'; }, wasDebugEnabled: function () { return false; }, saveUrl: function () {}, openAppDownload: function () {}, setFullscreen: function () {} }; } } catch (e) {}\n"
        }

        js += "})();\n"
        return js
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        init(_ parent: WebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            if let t = webView.title, !t.isEmpty { parent.pageTitle = t }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        /// 处理 target="_blank"：直接在同一个 WebView 里打开
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        /// 非 http(s) 的 scheme 交给系统（例如 itms-apps:）
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
