import SwiftUI
import AppKit
import WebKit

// MARK: - Segment model

enum ChatContentSegment: Identifiable, Equatable {
    /// Prose that may contain inline + display LaTeX — rendered as one HTML flow.
    case prose(String)
    case code(language: String, code: String)

    var id: String {
        switch self {
        case .prose(let s): return "prose-\(s.hashValue)"
        case .code(let lang, let code): return "code-\(lang)-\(code.hashValue)"
        }
    }
}

enum ChatContentParser {
    /// Split only on fenced code so math stays inside prose (inline `$…$` must
    /// not become its own vertical block — that orphaned commas/punctuation).
    static func parse(_ raw: String) -> [ChatContentSegment] {
        splitCodeFences(raw).filter { segment in
            switch segment {
            case .prose(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .code: return true
            }
        }
    }

    private static func splitCodeFences(_ text: String) -> [ChatContentSegment] {
        var segments: [ChatContentSegment] = []
        var remaining = text[...]
        while let open = remaining.range(of: "```") {
            let before = String(remaining[..<open.lowerBound])
            if !before.isEmpty { segments.append(.prose(before)) }
            remaining = remaining[open.upperBound...]
            let language: String
            let bodyStart: String.Index
            if let nl = remaining.firstIndex(of: "\n") {
                language = String(remaining[..<nl]).trimmingCharacters(in: .whitespaces)
                bodyStart = remaining.index(after: nl)
            } else {
                language = ""
                bodyStart = remaining.startIndex
            }
            remaining = remaining[bodyStart...]
            if let close = remaining.range(of: "```") {
                let code = String(remaining[..<close.lowerBound]).trimmingCharacters(in: .newlines)
                segments.append(.code(language: language, code: code))
                remaining = remaining[close.upperBound...]
            } else {
                segments.append(.prose("```" + (language.isEmpty ? "" : language + "\n") + String(remaining)))
                remaining = ""
            }
        }
        if !remaining.isEmpty {
            segments.append(.prose(String(remaining)))
        }
        return segments
    }
}

// MARK: - Rich message body

struct ChatRichContentView: View {
    let text: String
    var isStreaming = false
    var isError = false

    private var segments: [ChatContentSegment] {
        ChatContentParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let md):
                    ChatProseBlockView(markdown: md, isError: isError)
                case .code(let language, let code):
                    ChatCodeBlockView(language: language, code: code)
                }
            }
            if isStreaming {
                Circle()
                    .fill(Color.secondary.opacity(0.75))
                    .frame(width: 5, height: 5)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Prose (markdown + KaTeX in one WebView)

private struct ChatProseBlockView: View {
    let markdown: String
    var isError = false
    @State private var height: CGFloat = 24

    var body: some View {
        ChatProseWebView(markdown: markdown, isError: isError, height: $height)
            .frame(height: max(20, height))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatProseWebView: NSViewRepresentable {
    /// Shared process pool so remounts / sibling prose blocks reuse WebKit state.
    static let sharedProcessPool = WKProcessPool()

    let markdown: String
    let isError: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = ChatProseWebView.sharedProcessPool
        config.userContentController.add(context.coordinator, name: "height")
        let webView = ChatPassThroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        loadShell(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parentMarkdown = markdown
        context.coordinator.parentIsError = isError
        context.coordinator.renderIfReady()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    private func loadShell(into webView: WKWebView) {
        guard let index = katexIndexURL() else {
            webView.loadHTMLString("<p style='color:#f66;font:12px monospace'>KaTeX missing</p>", baseURL: nil)
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    private func katexIndexURL() -> URL? {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "katex") {
            return url
        }
        if let root = Bundle.main.resourceURL?.appendingPathComponent("katex/index.html"),
           FileManager.default.fileExists(atPath: root.path) {
            return root
        }
        return nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var parentMarkdown = ""
        var parentIsError = false
        weak var webView: WKWebView?
        private var ready = false
        private var lastKey = ""
        private var renderWork: DispatchWorkItem?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            lastKey = ""
            renderIfReady()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let value: CGFloat?
            if let d = message.body as? Double { value = CGFloat(d) }
            else if let i = message.body as? Int { value = CGFloat(i) }
            else { value = nil }
            guard let value, value > 0 else { return }
            DispatchQueue.main.async {
                // Avoid tiny jitter while streaming.
                if abs(self.height.wrappedValue - value) > 1 {
                    self.height.wrappedValue = value
                }
            }
        }

        func renderIfReady() {
            guard ready, let webView else { return }
            let key = "\(parentIsError)|\(parentMarkdown)"
            guard key != lastKey else { return }

            renderWork?.cancel()
            // Light debounce so token streaming doesn't thrash KaTeX every glyph.
            let work = DispatchWorkItem { [weak self] in
                guard let self, let webView = self.webView else { return }
                self.lastKey = key
                let b64 = Data(self.parentMarkdown.utf8).base64EncodedString()
                let js = "window.renderProse('\(b64)', \(self.parentIsError ? "true" : "false"));"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            renderWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }
}

/// WKWebView that forwards wheel/trackpad scrolls to the enclosing chat
/// ScrollView so hovering LLM text still scrolls the thread.
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

// MARK: - Code block

private struct ChatCodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textCase(.lowercase)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.25))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
