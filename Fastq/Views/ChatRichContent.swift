import SwiftUI
import AppKit
import WebKit

// MARK: - Rich message body
//
// One WKWebView per message renders the full markdown + math + code flow
// from the bundled ChatRenderer assets (marked + highlight.js + KaTeX, all
// local — works offline). Streaming updates go through a single JS call
// (`window.updateMessage`) that diffs the DOM block-by-block, so already
// rendered content never flickers while tokens arrive.

struct ChatRichContentView: View {
    let text: String
    var isStreaming = false
    var isError = false

    @State private var height: CGFloat

    init(text: String, isStreaming: Bool = false, isError: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
        self.isError = isError
        _height = State(initialValue: ChatContentHeightCache.shared.height(for: text) ?? 24)
    }

    var body: some View {
        ChatMarkdownWebView(
            markdown: text,
            isStreaming: isStreaming,
            isError: isError,
            height: $height
        )
        .frame(height: max(20, height))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Remembers rendered heights so LazyVStack re-mounts (scrolling back through
/// history) start at the right size instead of collapsing and re-expanding.
final class ChatContentHeightCache {
    static let shared = ChatContentHeightCache()
    private let cache = NSCache<NSString, NSNumber>()

    private init() {
        cache.countLimit = 400
    }

    private func key(for text: String) -> NSString {
        "\(text.hashValue)-\(text.count)" as NSString
    }

    func height(for text: String) -> CGFloat? {
        cache.object(forKey: key(for: text)).map { CGFloat($0.doubleValue) }
    }

    func store(_ height: CGFloat, for text: String) {
        cache.setObject(NSNumber(value: Double(height)), forKey: key(for: text))
    }
}

// MARK: - WebView host

private struct ChatMarkdownWebView: NSViewRepresentable {
    /// Shared process pool so message webviews reuse WebKit state.
    static let sharedProcessPool = WKProcessPool()

    let markdown: String
    let isStreaming: Bool
    let isError: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = ChatMarkdownWebView.sharedProcessPool
        config.userContentController.add(context.coordinator, name: "height")
        config.userContentController.add(context.coordinator, name: "copyCode")
        let webView = ChatPassThroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        loadShell(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingMarkdown = markdown
        context.coordinator.pendingIsStreaming = isStreaming
        context.coordinator.pendingIsError = isError
        context.coordinator.renderIfReady()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "copyCode")
    }

    private func loadShell(into webView: WKWebView) {
        guard let shell = Bundle.main.url(forResource: "chat", withExtension: "html", subdirectory: "ChatRenderer"),
              let resourceRoot = Bundle.main.resourceURL else {
            webView.loadHTMLString(
                "<p style='color:#f66;font:12px monospace'>ChatRenderer assets missing</p>",
                baseURL: nil
            )
            return
        }
        // Read access to the whole Resources dir: chat.html pulls KaTeX
        // (js/css/fonts) from the sibling katex/ folder.
        webView.loadFileURL(shell, allowingReadAccessTo: resourceRoot)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var pendingMarkdown = ""
        var pendingIsStreaming = false
        var pendingIsError = false
        weak var webView: WKWebView?

        private var ready = false
        private var lastKey = ""
        private var renderWork: DispatchWorkItem?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            lastKey = ""
            renderIfReady()
        }

        /// Links open in the default browser — never navigate the message view.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: Messages from JS

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "height":
                let value: CGFloat?
                if let d = message.body as? Double { value = CGFloat(d) }
                else if let i = message.body as? Int { value = CGFloat(i) }
                else { value = nil }
                guard let value, value > 0 else { return }
                let markdown = pendingMarkdown
                DispatchQueue.main.async {
                    // Ignore sub-point jitter while streaming.
                    if abs(self.height.wrappedValue - value) > 1 {
                        self.height.wrappedValue = value
                        ChatContentHeightCache.shared.store(value, for: markdown)
                    }
                }
            case "copyCode":
                if let code = message.body as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            default:
                break
            }
        }

        // MARK: Rendering

        func renderIfReady() {
            guard ready, webView != nil else { return }
            let key = "\(pendingIsError)|\(pendingIsStreaming)|\(pendingMarkdown)"
            guard key != lastKey else { return }

            renderWork?.cancel()
            // Light debounce so token streaming doesn't re-render every glyph;
            // the final (non-streaming) state always lands because it produces
            // its own key and work item.
            let work = DispatchWorkItem { [weak self] in
                guard let self, let webView = self.webView else { return }
                self.lastKey = "\(self.pendingIsError)|\(self.pendingIsStreaming)|\(self.pendingMarkdown)"
                let b64 = Data(self.pendingMarkdown.utf8).base64EncodedString()
                let js = "window.updateMessage('\(b64)', \(self.pendingIsStreaming), \(self.pendingIsError));"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            renderWork = work
            let delay: TimeInterval = pendingIsStreaming ? 0.05 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}

// MARK: - Scroll pass-through

/// WKWebView that forwards wheel/trackpad scrolls to the enclosing chat
/// ScrollView so hovering over message content still scrolls the thread.
private final class ChatPassThroughWebView: WKWebView {
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installScrollMonitor()
        } else {
            removeScrollMonitor()
        }
    }

    deinit {
        removeScrollMonitor()
    }

    override func scrollWheel(with event: NSEvent) {
        if let outer = outerChatScrollView() {
            outer.scrollWheel(with: event)
            return
        }
        nextResponder?.scrollWheel(with: event)
    }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        false
    }

    private func installScrollMonitor() {
        removeScrollMonitor()
        // Internal WK subviews often receive the wheel event before we do —
        // intercept while the pointer is over this web view and forward out.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window != nil, event.window === self.window else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            if let outer = self.outerChatScrollView() {
                outer.scrollWheel(with: event)
                return nil
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func outerChatScrollView() -> NSScrollView? {
        var view: NSView? = superview
        while let current = view {
            if let scroll = current as? NSScrollView {
                return scroll
            }
            view = current.superview
        }
        return nil
    }
}
