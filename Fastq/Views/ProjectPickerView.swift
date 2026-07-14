import SwiftUI
import AppKit

struct ProjectPickerView: View {
    let projects: [ProjectFolder]
    let recentIDs: [UUID]
    let selectedID: UUID?
    let onSelect: (ProjectFolder) -> Void
    let onAdd: () -> Void
    let onManage: () -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlightIndex = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [ProjectFolder] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [ProjectFolder]
        if trimmed.isEmpty {
            base = rankedProjects
        } else {
            base = rankedProjects.filter { project in
                project.name.localizedCaseInsensitiveContains(trimmed)
                    || project.path.localizedCaseInsensitiveContains(trimmed)
                    || fuzzyMatch(haystack: project.name, needle: trimmed)
            }
        }
        return base
    }

    private var rankedProjects: [ProjectFolder] {
        let recentSet = recentIDs
        let recents = recentSet.compactMap { id in projects.first(where: { $0.id == id }) }
        let rest = projects.filter { project in !recentSet.contains(project.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return recents + rest
    }

    private var recentFiltered: [ProjectFolder] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Array(filtered.prefix(while: { recentIDs.contains($0.id) }))
    }

    private var otherFiltered: [ProjectFolder] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filtered.filter { !recentIDs.contains($0.id) }
        }
        return filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.2)

            if projects.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResults
            } else {
                projectList
            }

            Divider().opacity(0.2)
            footer
        }
        .frame(width: 420)
        .frame(maxHeight: 360)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
        .onAppear {
            searchFocused = true
            highlightIndex = initialHighlightIndex()
        }
        .onChange(of: query) { _, _ in
            highlightIndex = filtered.isEmpty ? 0 : min(highlightIndex, filtered.count - 1)
        }
        .onExitCommand(perform: onDismiss)
        .background(KeyboardMonitor(
            onUp: { moveHighlight(-1) },
            onDown: { moveHighlight(1) }
        ))
    }

    // MARK: - Sections

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search projects…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($searchFocused)
                .onSubmit(confirmSelection)

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
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !recentFiltered.isEmpty {
                        sectionLabel("Recent")
                        ForEach(Array(recentFiltered.enumerated()), id: \.element.id) { _, project in
                            row(for: project, globalIndex: index(of: project))
                        }
                    }

                    if !otherFiltered.isEmpty {
                        if !recentFiltered.isEmpty {
                            sectionLabel(query.isEmpty ? "All projects" : "Results")
                        } else if !query.isEmpty {
                            sectionLabel("Results")
                        } else {
                            sectionLabel("Projects")
                        }
                        ForEach(Array(otherFiltered.enumerated()), id: \.element.id) { _, project in
                            row(for: project, globalIndex: index(of: project))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: highlightIndex) { _, newValue in
                guard filtered.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(filtered[newValue].id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private func row(for project: ProjectFolder, globalIndex: Int) -> some View {
        let isHighlighted = globalIndex == highlightIndex
        let isSelected = project.id == selectedID

        return Button {
            onSelect(project)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(isHighlighted ? 0.14 : 0.07))
                        .frame(width: 28, height: 28)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.95, green: 0.42, blue: 0.28))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(abbreviatedPath(project.path))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(project.path)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHighlighted ? Color.white.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(project.id)
        .onHover { hovering in
            if hovering {
                highlightIndex = globalIndex
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.system(size: 14, weight: .semibold))
            Text("Add a folder to start launching agents into it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Folder…", action: onAdd)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Text("No matches for “\(query)”")
                .font(.system(size: 13, weight: .medium))
            Text("Try another name, or add a new folder.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Add Folder…", action: onAdd)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.link)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                onAdd()
            } label: {
                Label("Add Folder", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                onManage()
            } label: {
                Text("Manage")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 8) {
                FooterKeyHint(label: "Select", key: "↩")
                FooterKeyHint(label: "Close", key: "Esc")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.18))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    // MARK: - Logic

    private func index(of project: ProjectFolder) -> Int {
        filtered.firstIndex(where: { $0.id == project.id }) ?? 0
    }

    private func initialHighlightIndex() -> Int {
        if let selectedID, let idx = filtered.firstIndex(where: { $0.id == selectedID }) {
            return idx
        }
        return 0
    }

    private func moveHighlight(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let next = (highlightIndex + delta + filtered.count) % filtered.count
        highlightIndex = next
    }

    private func confirmSelection() {
        guard filtered.indices.contains(highlightIndex) else { return }
        onSelect(filtered[highlightIndex])
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        let display = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = display.split(separator: "/")
        if parts.count <= 3 { return display }
        return parts.suffix(3).joined(separator: "/")
    }

    private func fuzzyMatch(haystack: String, needle: String) -> Bool {
        let h = haystack.lowercased()
        let n = needle.lowercased()
        var i = h.startIndex
        for ch in n {
            guard let found = h[i...].firstIndex(of: ch) else { return false }
            i = h.index(after: found)
        }
        return true
    }
}

private struct FooterKeyHint: View {
    let label: String
    let key: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(.secondary)
        }
    }
}

/// Captures ↑/↓ while the search field has focus. Esc is handled by LauncherPanelController.
private struct KeyboardMonitor: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherView()
        view.onUp = onUp
        view.onDown = onDown
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCatcherView else { return }
        view.onUp = onUp
        view.onDown = onDown
    }
}

private final class KeyCatcherView: NSView {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 126:
                    self.onUp?()
                    return nil
                case 125:
                    self.onDown?()
                    return nil
                default:
                    return event
                }
            }
        }
        if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
