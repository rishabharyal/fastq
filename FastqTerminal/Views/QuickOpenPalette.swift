import SwiftUI
import AppKit

/// ⌘P quick-open: fuzzy file picker over the active project.
struct QuickOpenPalette: View {
    @ObservedObject var model: FileBrowserModel
    @Binding var isPresented: Bool
    var onOpen: (URL) -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var results: [FileNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            // Recent-ish: show a shallow sample from the root tree.
            return (model.children[model.rootPath ?? ""] ?? [])
                .filter { !$0.isDirectory }
                .prefix(40)
                .map { $0 }
        }
        return model.searchResults
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Go to file…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($fieldFocused)
                        .onSubmit { openSelected() }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().overlay(Color.primary.opacity(0.1))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if results.isEmpty {
                                Text(query.isEmpty ? "Type to search files" : "No matches")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            } else {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, node in
                                    QuickOpenRow(
                                        node: node,
                                        root: model.rootPath ?? "",
                                        isSelected: index == selection
                                    )
                                    .id(index)
                                    .onTapGesture {
                                        selection = index
                                        openSelected()
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, value in
                        proxy.scrollTo(value, anchor: .center)
                    }
                }
            }
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 28, y: 10)
        }
        .onAppear {
            fieldFocused = true
            selection = 0
            model.searchText = ""
        }
        .onChange(of: query) { _, value in
            selection = 0
            model.searchText = value
        }
        .onExitCommand { dismiss() }
        .background(QuickOpenKeyMonitor(
            onUp: {
                guard !results.isEmpty else { return }
                selection = max(0, selection - 1)
            },
            onDown: {
                guard !results.isEmpty else { return }
                selection = min(results.count - 1, selection + 1)
            },
            onEscape: dismiss
        ))
    }

    private func openSelected() {
        guard results.indices.contains(selection) else { return }
        onOpen(results[selection].url)
        dismiss()
    }

    private func dismiss() {
        query = ""
        model.searchText = ""
        isPresented = false
    }
}

private struct QuickOpenRow: View {
    let node: FileNode
    let root: String
    let isSelected: Bool

    private var relative: String {
        let path = node.url.path
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(relative)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
    }
}

/// Local key monitor while the palette is up (↑↓ Esc).
private struct QuickOpenKeyMonitor: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUp = onUp
        context.coordinator.onDown = onDown
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onUp: onUp, onDown: onDown, onEscape: onEscape)
    }

    final class Coordinator {
        var onUp: () -> Void
        var onDown: () -> Void
        var onEscape: () -> Void
        private var monitor: Any?

        init(onUp: @escaping () -> Void, onDown: @escaping () -> Void, onEscape: @escaping () -> Void) {
            self.onUp = onUp
            self.onDown = onDown
            self.onEscape = onEscape
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 126: self.onUp(); return nil
                case 125: self.onDown(); return nil
                case 53: self.onEscape(); return nil
                default: return event
                }
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { remove() }
    }
}
