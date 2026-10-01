import SwiftUI
import WebKit
import UIKit

/// User-Agent 模式。
/// 官方安卓 App 用的就是「桌面 Chrome」的 UA（从 bigtree.apk 里挖出来的），
/// 借它让 ibutv 认为访问者是桌面浏览器，而不是"被禁用的手机"。
enum UAMode: String, CaseIterable, Identifiable {
    case plugin
    case desktop
    case android
    case iosDefault

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plugin:     return "插件版"
        case .desktop:    return "桌面"
        case .android:    return "安卓"
        case .iosDefault: return "iOS"
        }
    }

    /// 返回 nil 表示用系统默认 UA
    var userAgent: String? {
        switch self {
        case .plugin:
            // ★ 关键一：ibutv 判断"插件装没装"用的是
            //    /xstree|ibutv|bigtree/i.test(navigator.userAgent)
            //    带这几个词之一，网站就认为插件已安装，
            //    那些"需要插件的源"（B站/优酷/芒果/种子）才会解锁。
            // ★ 关键二：网站读版本号**只认 UA 里的 `bigtree/<版本号>`**：
            //    f = (ua.match(/bigtree\/([\d.]+)/i) || [])[1]
            //    读不到就把你当成"版本过旧的插件"，弹「APP版本过旧」。
            //    这里写成当前最新版 1.13，避免弹升级提示。
            // ★ 关键三：保留 xstree 前缀，让它认成"浏览器插件"而不是安卓 App，
            //    否则升级弹窗会出现安卓 APK 下载按钮。
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 xstree/1.13 bigtree/1.13"
        case .desktop:
            // 与 bigtree.apk 中硬编码的 UA 完全一致（不带插件标识）
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        case .android:
            return "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
        case .iosDefault:
            return nil
        }
    }
}

/// 接收网页 JS 发来的视频流地址
final class StreamBridge: NSObject, WKScriptMessageHandler {
    var onStream: ((String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String, type == "stream",
              let url = body["url"] as? String, !url.isEmpty else { return }
        onStream?(url)
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

    var hideCloseButton: Bool
    var onStream: (String) -> Void
    var onWebView: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(iOS 15.4, *) {
            config.preferences.isElementFullscreenEnabled = true
        }

        // 注入脚本：补发插件就绪信号 + 捕获视频流地址 + 原生桥存根
        let script = WKUserScript(source: WebView.injectedJS(fakeApp: fakeApp,
                                                            hideCloseButton: hideCloseButton),
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        config.userContentController.addUserScript(script)

        // 流捕获桥
        let bridge = StreamBridge()
        bridge.onStream = onStream
        config.userContentController.add(bridge, name: "bigtree")
        context.coordinator.bridge = bridge

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

    /// 注入到网页的脚本（全部用单行拼接，避免 Swift 多行字符串的缩进规则）
    static func injectedJS(fakeApp: Bool, hideCloseButton: Bool) -> String {
        var js = "(function () {\n"

        // 1) 让 ibutv 认为 xstree 插件已就绪
        js += "try { window.__rulesReady = true; } catch (e) {}\n"
        js += "try { setInterval(function () { try { window.postMessage({ type: 'RULES_READY' }, location.origin); } catch (e) {} }, 1000); } catch (e) {}\n"

        // 2) 官方 App 的原生桥存根（避免网页调用报错）
        js += "try {\n"
        js += "if (typeof window.__bigtreeRemoteCommand !== 'function') { window.__bigtreeRemoteCommand = function () { return 0; }; }\n"
        js += "if (typeof window.__exitPlayerFullscreen !== 'function') { window.__exitPlayerFullscreen = function () { try { var el = document.fullscreenElement || document.webkitFullscreenElement; if (el) { (document.exitFullscreen || document.webkitExitFullscreen).call(document); return 1; } } catch (e) {} return 0; }; }\n"
        js += "window.__urlWatcher = true;\n"
        js += "} catch (e) {}\n"

        // 3) 视频流地址捕获（m3u8 / mpd / skd://）—— 供原生 FairPlay 播放器使用
        js += "try {\n"
        js += "if (!window.__streamWatcher) {\n"
        js += "window.__streamWatcher = true;\n"
        js += "window.__capturedStreams = [];\n"
        js += "window.__reportStream = function (u) { try { if (!u || typeof u !== 'string') return; if (u.indexOf('.m3u8') === -1 && u.indexOf('skd://') === -1 && u.indexOf('.mpd') === -1) return; if (window.__capturedStreams.indexOf(u) !== -1) return; window.__capturedStreams.push(u); if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bigtree) { window.webkit.messageHandlers.bigtree.postMessage({ type: 'stream', url: u }); } } catch (e) {} };\n"
        js += "var __of = window.fetch;\n"
        js += "if (__of) { window.fetch = function () { try { var a = arguments[0]; window.__reportStream(a && a.url ? a.url : a); } catch (e) {} return __of.apply(this, arguments); }; }\n"
        js += "var __oo = XMLHttpRequest.prototype.open;\n"
        js += "XMLHttpRequest.prototype.open = function (m, u) { try { window.__reportStream(u); } catch (e) {} return __oo.apply(this, arguments); };\n"
        js += "document.addEventListener('loadedmetadata', function (e) { try { if (e.target && e.target.src) window.__reportStream(e.target.src); } catch (e2) {} }, true);\n"
        js += "setInterval(function () { try { var vs = document.querySelectorAll('video'); for (var i = 0; i < vs.length; i++) { if (vs[i].src) window.__reportStream(vs[i].src); if (vs[i].currentSrc) window.__reportStream(vs[i].currentSrc); } } catch (e) {} }, 2000);\n"
        js += "}\n"
        js += "} catch (e) {}\n"

        // 4) 可选：伪造 window.Android，让 ibutv 把本 App 当成官方安卓客户端
        if fakeApp {
            js += "try { if (!window.Android) { window.Android = { getVersion: function () { return '1.0.8'; }, wasDebugEnabled: function () { return false; }, saveUrl: function () {}, openAppDownload: function () {}, setFullscreen: function () {} }; } } catch (e) {}\n"
        }

        // 5) 隐藏网页自带的"退出全屏"按钮（左上角那个 ×），
        //    改为双击画面退出全屏，避免全屏后没法退出。
        if hideCloseButton {
            js += "try { var __st = document.createElement('style'); __st.textContent = '.close-full{display:none !important;}'; (document.head || document.documentElement).appendChild(__st); document.addEventListener('DOMContentLoaded', function () { try { (document.head || document.documentElement).appendChild(__st); } catch (e) {} }); } catch (e) {}\n"
            js += "try { document.addEventListener('dblclick', function (ev) { try { var b = document.querySelector('.close-full'); if (b && b.offsetParent !== null) { b.click(); } } catch (e2) {} }, true); } catch (e) {}\n"
        }

        js += "})();\n"
        return js
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        var bridge: StreamBridge?

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

        /// target="_blank" 直接在同一个 WebView 里打开
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        /// 非 http(s) 的 scheme 交给系统
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
