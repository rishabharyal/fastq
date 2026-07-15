import SwiftUI
import AppKit
import WebKit

/// Broadcast editor actions to the focused Monaco surface.
enum EditorCommand: String {
    case find, replace, goToLine, goToSymbol, commandPalette
    case format, toggleComment, toggleWordWrap
    case zoomIn, zoomOut, zoomReset
    case foldAll, unfoldAll
    case focus
}

extension Notification.Name {
    static let fastqEditorCommand = Notification.Name("fastq.editorCommand")
    static let fastqEditorEvent = Notification.Name("fastq.editorEvent")
}

/// Monaco editor hosted in WKWebView (local AMD build under Resources/monaco).
struct MonacoEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: String
    var onSave: (() -> Void)?
    var onQuickOpen: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onNextTab: (() -> Void)?
    var onPrevTab: (() -> Void)?
    var onSaveAll: (() -> Void)?
    var onCursorChange: ((Int, Int, Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.userContentController.add(context.coordinator, name: "fastq")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.language = language
        context.coordinator.attachCommandObserver()

        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "monaco") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        } else if let index = monacoIndexURL() {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.language = language
        context.coordinator.pushContentIfNeeded(text: text, language: language)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "fastq")
    }

    private func monacoIndexURL() -> URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let index = root.appendingPathComponent("monaco/index.html")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MonacoEditorView
        var language: String = "plaintext"
        weak var webView: WKWebView?
        private var isReady = false
        private var lastPushed: String?
        private var pendingText: String?
        private var commandObserver: NSObjectProtocol?

        init(parent: MonacoEditorView) {
            self.parent = parent
        }

        func attachCommandObserver() {
            guard commandObserver == nil else { return }
            commandObserver = NotificationCenter.default.addObserver(
                forName: .fastqEditorCommand,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let raw = note.object as? String,
                      let command = EditorCommand(rawValue: raw)
                else { return }
                Task { @MainActor in
                    self?.run(command)
                }
            }
        }

        func detach() {
            if let commandObserver {
                NotificationCenter.default.removeObserver(commandObserver)
            }
            commandObserver = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pushContentIfNeeded(
                    text: self?.parent.text ?? "",
                    language: self?.language ?? "plaintext",
                    force: true
                )
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            switch type {
            case "ready":
                isReady = true
                let value = pendingText ?? parent.text
                pendingText = nil
                pushContentIfNeeded(text: value, language: language, force: true)
            case "change":
                if let newText = body["text"] as? String {
                    lastPushed = newText
                    if parent.text != newText {
                        parent.text = newText
                    }
                }
            case "save":
                parent.onSave?()
            case "saveAll":
                parent.onSaveAll?()
            case "quickOpen":
                parent.onQuickOpen?()
            case "closeTab":
                parent.onCloseTab?()
            case "nextTab":
                parent.onNextTab?()
            case "prevTab":
                parent.onPrevTab?()
            case "cursor":
                let line = body["line"] as? Int ?? 1
                let column = body["column"] as? Int ?? 1
                let selected = body["selected"] as? Int ?? 0
                parent.onCursorChange?(line, column, selected)
            default:
                break
            }
        }

        func run(_ command: EditorCommand) {
            guard isReady, let webView else { return }
            let js: String
            switch command {
            case .find: js = "window.fastqEditor && window.fastqEditor.find()"
            case .replace: js = "window.fastqEditor && window.fastqEditor.replace()"
            case .goToLine: js = "window.fastqEditor && window.fastqEditor.goToLine()"
            case .goToSymbol: js = "window.fastqEditor && window.fastqEditor.goToSymbol()"
            case .commandPalette: js = "window.fastqEditor && window.fastqEditor.commandPalette()"
            case .format: js = "window.fastqEditor && window.fastqEditor.format()"
            case .toggleComment: js = "window.fastqEditor && window.fastqEditor.toggleComment()"
            case .toggleWordWrap: js = "window.fastqEditor && window.fastqEditor.toggleWordWrap()"
            case .zoomIn: js = "window.fastqEditor && window.fastqEditor.bumpFontSize(1)"
            case .zoomOut: js = "window.fastqEditor && window.fastqEditor.bumpFontSize(-1)"
            case .zoomReset: js = "window.fastqEditor && window.fastqEditor.resetFontSize()"
            case .foldAll: js = "window.fastqEditor && window.fastqEditor.foldAll()"
            case .unfoldAll: js = "window.fastqEditor && window.fastqEditor.unfoldAll()"
            case .focus: js = "window.fastqEditor && window.fastqEditor.focus()"
            }
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func pushContentIfNeeded(text: String, language: String, force: Bool = false) {
            guard isReady, let webView else {
                pendingText = text
                return
            }
            if !force, lastPushed == text { return }
            lastPushed = text

            let escapedText = Data(text.utf8).base64EncodedString()
            let escapedLang = language
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            let js = """
            (function(){
              if (!window.fastqEditor || !window.fastqEditor.isReady()) return;
              var binary = atob('\(escapedText)');
              var bytes = new Uint8Array(binary.length);
              for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
              var text = new TextDecoder('utf-8').decode(bytes);
              window.fastqEditor.setContent(text, '\(escapedLang)');
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

enum MonacoLanguage {
    static func detect(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "mts", "cts", "tsx": return "typescript"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "xml", "plist": return "xml"
        case "yml", "yaml": return "yaml"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m", "mm": return "objective-c"
        case "sh", "bash", "zsh": return "shell"
        case "sql": return "sql"
        case "graphql", "gql": return "graphql"
        case "dockerfile": return "dockerfile"
        case "toml", "ini", "cfg", "conf": return "ini"
        case "r": return "r"
        case "php": return "php"
        case "cs": return "csharp"
        case "dart": return "dart"
        case "lua": return "lua"
        default:
            let name = url.lastPathComponent.lowercased()
            if name == "dockerfile" { return "dockerfile" }
            if name == "gemfile" || name == "rakefile" { return "ruby" }
            return "plaintext"
        }
    }
}
