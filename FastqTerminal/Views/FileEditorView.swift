import SwiftUI
import AppKit
import Combine

// MARK: - Open documents

@MainActor
final class EditorDocument: Identifiable, ObservableObject {
    let id: String
    let url: URL
    @Published var text: String
    @Published var isDirty = false
    let isBinary: Bool
    let loadError: String?

    private var savedText: String

    var breadcrumbs: [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    init(url: URL) {
        self.id = url.path
        self.url = url
        if let data = try? Data(contentsOf: url) {
            if Self.looksBinary(data) {
                self.text = ""
                self.savedText = ""
                self.isBinary = true
                self.loadError = nil
            } else if let string = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) {
                self.text = string
                self.savedText = string
                self.isBinary = false
                self.loadError = nil
            } else {
                self.text = ""
                self.savedText = ""
                self.isBinary = true
                self.loadError = "Could not decode file as text."
            }
        } else {
            self.text = ""
            self.savedText = ""
            self.isBinary = false
            self.loadError = "Could not read file."
        }
    }

    func markEdited(_ newText: String) {
        text = newText
        isDirty = newText != savedText
    }

    @discardableResult
    func save() -> Bool {
        guard !isBinary, loadError == nil else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            isDirty = false
            return true
        } catch {
            return false
        }
    }

    private static func looksBinary(_ data: Data) -> Bool {
        if data.contains(0) { return true }
        let sample = data.prefix(512)
        let nonPrintable = sample.filter { byte in
            (byte < 9) || (byte > 13 && byte < 32)
        }.count
        return sample.count > 0 && Double(nonPrintable) / Double(sample.count) > 0.3
    }
}

@MainActor
final class EditorStore: ObservableObject {
    @Published private(set) var documents: [EditorDocument] = []
    @Published var activeID: String?
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var selectionLength = 0

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeID } ?? documents.first
    }

    var activeIndex: Int? {
        guard let activeID else { return nil }
        return documents.firstIndex(where: { $0.id == activeID })
    }

    func open(_ url: URL) {
        let path = url.path
        if let existing = documents.first(where: { $0.id == path }) {
            activeID = existing.id
            return
        }
        let doc = EditorDocument(url: url)
        documents.append(doc)
        activeID = doc.id
    }

    func close(_ id: String) {
        documents.removeAll { $0.id == id }
        if activeID == id {
            activeID = documents.last?.id
        }
    }

    func closeActive() {
        guard let id = activeID else { return }
        close(id)
    }

    func selectNextTab() {
        guard let index = activeIndex, !documents.isEmpty else { return }
        let next = (index + 1) % documents.count
        activeID = documents[next].id
    }

    func selectPreviousTab() {
        guard let index = activeIndex, !documents.isEmpty else { return }
        let prev = (index - 1 + documents.count) % documents.count
        activeID = documents[prev].id
    }

    @discardableResult
    func saveActive() -> Bool {
        activeDocument?.save() ?? false
    }

    func saveAll() {
        for doc in documents where doc.isDirty {
            _ = doc.save()
        }
    }

    func updateCursor(line: Int, column: Int, selected: Int) {
        cursorLine = line
        cursorColumn = column
        selectionLength = selected
    }
}

// MARK: - Editor view

struct FileEditorView: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var store: EditorStore
    var onQuickOpen: (() -> Void)?
    var projectRoot: String?

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider().overlay(Color.primary.opacity(0.08))

            if let error = document.loadError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if document.isBinary {
                binaryPlaceholder
            } else {
                MonacoEditorView(
                    text: Binding(
                        get: { document.text },
                        set: {
                            document.markEdited($0)
                            store.objectWillChange.send()
                        }
                    ),
                    language: MonacoLanguage.detect(for: document.url),
                    onSave: { _ = document.save() },
                    onQuickOpen: onQuickOpen,
                    onCloseTab: { store.close(document.id) },
                    onNextTab: { store.selectNextTab() },
                    onPrevTab: { store.selectPreviousTab() },
                    onSaveAll: { store.saveAll() },
                    onCursorChange: { line, column, selected in
                        store.updateCursor(line: line, column: column, selected: selected)
                    }
                )
            }

            statusBar
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            let parts = relativeBreadcrumbs
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                Text(part)
                    .font(.system(size: 11, weight: index == parts.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == parts.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if document.isDirty {
                Button("Save") { _ = document.save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .keyboardShortcut("s", modifiers: .command)
            }
            Menu {
                Button("Copy Path") { copy(document.url.path) }
                Button("Copy Relative Path") { copy(relativePath) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([document.url])
                }
                Divider()
                Button("Find…") { notify(.find) }
                Button("Replace…") { notify(.replace) }
                Button("Go to Line…") { notify(.goToLine) }
                Button("Go to Symbol…") { notify(.goToSymbol) }
                Divider()
                Button("Format Document") { notify(.format) }
                Button("Toggle Word Wrap") { notify(.toggleWordWrap) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("Ln \(store.cursorLine), Col \(store.cursorColumn)")
            if store.selectionLength > 0 {
                Text("(\(store.selectionLength) selected)")
            }
            Spacer()
            Text("UTF-8")
            Text("LF")
            Text("Spaces: 2")
            Text(MonacoLanguage.detect(for: document.url))
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
    }

    private var binaryPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.35))
            Text("Binary file")
                .font(.headline)
            Button("Open with default app") {
                NSWorkspace.shared.open(document.url)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var relativePath: String {
        guard let root = projectRoot, document.url.path.hasPrefix(root) else {
            return document.url.path
        }
        return String(document.url.path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    private var relativeBreadcrumbs: [String] {
        let parts = relativePath.split(separator: "/").map(String.init)
        return parts.isEmpty ? [document.url.lastPathComponent] : parts
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func notify(_ command: EditorCommand) {
        NotificationCenter.default.post(name: .fastqEditorCommand, object: command.rawValue)
    }
}
