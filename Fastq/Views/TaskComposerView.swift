import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Full create-task form: title, description, column, priority, dates,
/// labels, assignees, and file attachments — everything the API accepts.
/// Presented as a sheet from the Boards window and as an overlay card in
/// the launcher.
struct TaskComposerView: View {
    @ObservedObject var store: BoardStore
    var initialColumnID: String?
    var initialTitle: String = ""
    var initialAttachments: [URL] = []
    var onCreated: (FastplayTask) -> Void
    var onCancel: () -> Void

    @State private var draft = FastplayTaskDraft()
    @State private var hasStartDate = false
    @State private var hasDueDate = false
    @State private var startDate = Date()
    @State private var dueDate = Date()
    @State private var selectedLabelIDs: Set<String> = []
    @State private var selectedAssignees: [FastplayUser] = []
    @State private var assigneeQuery = ""
    @State private var assigneeResults: [FastplayUser] = []
    @State private var assigneeSearchTask: Task<Void, Never>?
    @State private var attachmentURLs: [URL] = []
    @State private var isSubmitting = false
    @State private var progressText: String?
    @State private var errorText: String?
    @State private var showNewLabel = false
    @State private var newLabelName = ""
    @State private var newLabelColor = LabelColorPalette.all[0]
    @State private var isDropTargeted = false
    @State private var pasteMonitor: Any?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleField
                    descriptionField
                    HStack(spacing: 10) {
                        columnPicker
                        priorityPicker
                        Spacer(minLength: 0)
                    }
                    datesSection
                    labelsSection
                    assigneesSection
                    attachmentsSection
                }
                .padding(16)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 380, maxHeight: 600)
        .onAppear {
            draft.columnID = initialColumnID ?? store.selectedColumnID
            draft.title = initialTitle
            attachmentURLs = initialAttachments
            titleFocused = true
            Task { await store.refreshLabels() }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear(perform: installPasteMonitor)
        .onDisappear(perform: removePasteMonitor)
    }

    /// ⌘V with files or a screenshot on the clipboard attaches them; plain
    /// text falls through to the focused field.
    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == .command, event.charactersIgnoringModifiers == "v" else { return event }
            let files = PasteboardFiles.read()
            guard !files.isEmpty else { return event }
            DispatchQueue.main.async {
                appendFiles(files)
            }
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
            self.pasteMonitor = nil
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Text("New task")
                .font(FQTheme.fontTitle)
            if let project = store.selectedProject {
                Text("in \(project.name)")
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textSecondary)
            }
            Spacer()
            FQIconButton(systemImage: "xmark", size: 24, iconSize: 10, help: "Close") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.danger)
                    .lineLimit(2)
            } else if let progressText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progressText)
                        .font(FQTheme.fontSmall)
                        .foregroundStyle(FQTheme.textSecondary)
                }
            }
            Spacer()
            FQButton(title: "Cancel", variant: .ghost) {
                onCancel()
            }
            FQButton(
                title: isSubmitting ? "Creating…" : "Create task",
                variant: .primary,
                isLoading: isSubmitting
            ) {
                submit()
            }
            .keyboardShortcut(.defaultAction)
            .opacity(canSubmit ? 1 : 0.5)
            .allowsHitTesting(canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.selectedProject != nil
    }

    // MARK: - Fields

    private var titleField: some View {
        TextField("Task title", text: $draft.title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1...3)
            .focused($titleFocused)
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Description")
            MentionTextEditor(
                text: $draft.description,
                placeholder: "Add more detail…",
                workspaceID: store.selectedWorkspaceID,
                projectID: store.selectedProjectID
            )
        }
    }

    private var columnPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Column")
            FQMenuChip(title: selectedColumnName, systemImage: "square.stack") {
                ForEach(sortedColumns) { column in
                    Button {
                        draft.columnID = column.id
                    } label: {
                        if column.id == draft.columnID {
                            Label(column.name, systemImage: "checkmark")
                        } else {
                            Text(column.name)
                        }
                    }
                }
            }
        }
    }

    private var selectedColumnName: String {
        sortedColumns.first { $0.id == draft.columnID }?.name
            ?? sortedColumns.first?.name
            ?? "Column"
    }

    private var sortedColumns: [FastplayColumn] {
        (store.board?.columns ?? []).sorted { $0.position < $1.position }
    }

    private var priorityPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Priority")
            FQMenuChip(
                title: draft.priority.flatMap { TaskPriority(rawValue: $0)?.displayName } ?? "None",
                systemImage: draft.priority.flatMap { TaskPriority(rawValue: $0)?.systemImage } ?? "minus"
            ) {
                Button("None") { draft.priority = nil }
                ForEach(TaskPriority.allCases) { p in
                    Button {
                        draft.priority = p.rawValue
                    } label: {
                        if draft.priority == p.rawValue {
                            Label(p.displayName, systemImage: "checkmark")
                        } else {
                            Label(p.displayName, systemImage: p.systemImage)
                        }
                    }
                }
            }
        }
    }

    private var datesSection: some View {
        HStack(spacing: 16) {
            optionalDate(label: "Start date", isOn: $hasStartDate, date: $startDate)
            optionalDate(label: "Due date", isOn: $hasDueDate, date: $dueDate)
            Spacer(minLength: 0)
        }
    }

    private func optionalDate(label: String, isOn: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack(spacing: 6) {
            if isOn.wrappedValue {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle(label)
                    HStack(spacing: 4) {
                        DatePicker("", selection: date, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                        FQIconButton(systemImage: "xmark.circle.fill", size: 20, iconSize: 10, help: "Remove \(label.lowercased())") {
                            isOn.wrappedValue = false
                        }
                    }
                }
            } else {
                FQButton(title: label, systemImage: "calendar.badge.plus", variant: .outline, size: .small) {
                    isOn.wrappedValue = true
                }
            }
        }
    }

    // MARK: - Labels

    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Labels")
            FlowLayout(spacing: 6) {
                ForEach(store.workspaceLabels) { label in
                    labelToggle(label)
                }
                newLabelButton
            }
        }
    }

    private func labelToggle(_ label: FastplayLabel) -> some View {
        let selected = selectedLabelIDs.contains(label.id)
        return Button {
            if selected {
                selectedLabelIDs.remove(label.id)
            } else {
                selectedLabelIDs.insert(label.id)
            }
        } label: {
            LabelChipView(label: label)
                .overlay(
                    Capsule().strokeBorder(
                        selected ? Color(hexString: label.color) : Color.clear,
                        lineWidth: 1.5
                    )
                )
                .opacity(selected ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label.name)\(selected ? ", selected" : "")")
    }

    private var newLabelButton: some View {
        Button {
            showNewLabel = true
        } label: {
            Label("New label", systemImage: "plus")
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showNewLabel, arrowEdge: .bottom) {
            newLabelPopover
        }
    }

    private var newLabelPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            FQTextField(placeholder: "Label name", text: $newLabelName)
                .frame(width: 200)
            HStack(spacing: 6) {
                ForEach(LabelColorPalette.all, id: \.self) { hex in
                    Button {
                        newLabelColor = hex
                    } label: {
                        Circle()
                            .fill(Color(hexString: hex))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(
                                    newLabelColor == hex ? Color.primary : Color.clear,
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            FQButton(title: "Add label", variant: .primary, size: .small) {
                let name = newLabelName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    if let label = await store.createLabel(name: name, color: newLabelColor) {
                        selectedLabelIDs.insert(label.id)
                    }
                    newLabelName = ""
                    showNewLabel = false
                }
            }
            .opacity(newLabelName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(12)
    }

    // MARK: - Assignees

    private var assigneesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Assignees")
            if !selectedAssignees.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(selectedAssignees) { user in
                        HStack(spacing: 5) {
                            AvatarBubble(name: user.name.isEmpty ? user.email : user.name, size: 16)
                            Text(user.name.isEmpty ? user.email : user.name)
                                .font(.system(size: 11, weight: .medium))
                            Button {
                                selectedAssignees.removeAll { $0.id == user.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(user.name)")
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }
            FQTextField(placeholder: "Search people…", text: $assigneeQuery)
                .frame(maxWidth: 260)
                .onChange(of: assigneeQuery) { _, query in
                    searchAssignees(query)
                }
            if !assigneeResults.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(assigneeResults.prefix(5)) { user in
                        Button {
                            if !selectedAssignees.contains(where: { $0.id == user.id }) {
                                selectedAssignees.append(user)
                            }
                            assigneeQuery = ""
                            assigneeResults = []
                        } label: {
                            HStack(spacing: 8) {
                                AvatarBubble(name: user.name.isEmpty ? user.email : user.name, size: 18)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(user.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(user.email)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .frame(maxWidth: 320)
            }
        }
    }

    private func searchAssignees(_ query: String) {
        assigneeSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            assigneeResults = []
            return
        }
        let workspaceID = store.selectedWorkspaceID
        assigneeSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let results = (try? await FastplayAPIClient.shared.searchUsers(query: trimmed, workspaceID: workspaceID)) ?? []
            guard !Task.isCancelled else { return }
            assigneeResults = results
        }
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Attachments")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(attachmentURLs, id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: url))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            attachmentURLs.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                FQButton(
                    title: attachmentURLs.isEmpty ? "Add files… (or drop them here)" : "Add more files…",
                    systemImage: "paperclip",
                    variant: .outline,
                    size: .small
                ) {
                    pickFiles()
                }
            }
            .padding(isDropTargeted ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.clear,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4])
                    )
            )
        }
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "zip": return "archivebox"
        default: return "doc"
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        appendFiles(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url {
                    DispatchQueue.main.async {
                        appendFiles([url])
                    }
                }
            }
        }
        return handled
    }

    private func appendFiles(_ urls: [URL]) {
        for url in urls where !attachmentURLs.contains(url) {
            attachmentURLs.append(url)
        }
    }

    // MARK: - Submit

    private func submit() {
        guard canSubmit else { return }
        errorText = nil
        isSubmitting = true
        var payload = draft
        payload.startDate = hasStartDate ? startDate : nil
        payload.dueDate = hasDueDate ? dueDate : nil
        payload.labelIDs = Array(selectedLabelIDs)
        payload.assigneeIDs = selectedAssignees.map(\.id)
        payload.attachmentURLs = attachmentURLs
        Task {
            defer {
                isSubmitting = false
                progressText = nil
            }
            do {
                let task = try await store.createTask(draft: payload) { index, total in
                    progressText = "Uploading attachment \(index) of \(total)…"
                }
                onCreated(task)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// Presents the task composer / task detail in standalone floating windows.
/// The launcher panel is borderless and fights embedded text fields for key
/// focus, so modals get real windows instead of in-panel overlays.
@MainActor
final class TaskModalWindows {
    static let shared = TaskModalWindows()

    private var composerWindow: NSWindow?
    private var detailWindow: NSWindow?

    func showComposer(
        store: BoardStore,
        initialColumnID: String?,
        initialTitle: String,
        attachments: [URL],
        onCreated: @escaping (FastplayTask) -> Void
    ) {
        composerWindow?.close()
        let view = TaskComposerView(
            store: store,
            initialColumnID: initialColumnID,
            initialTitle: initialTitle,
            initialAttachments: attachments,
            onCreated: { [weak self] task in
                onCreated(task)
                self?.composerWindow?.close()
                self?.composerWindow = nil
            },
            onCancel: { [weak self] in
                self?.composerWindow?.close()
                self?.composerWindow = nil
            }
        )
        composerWindow = present(view, title: "New Task")
    }

    func showDetail(
        task: FastplayTask,
        store: BoardStore,
        onStartAgent: ((FastplayTask) -> Void)? = nil
    ) {
        detailWindow?.close()
        let view = TaskDetailView(
            task: task,
            boardStore: store,
            onClose: { [weak self] in
                self?.detailWindow?.close()
                self?.detailWindow = nil
            },
            onStartAgent: onStartAgent.map { start in
                { [weak self] task in
                    // Hand off to the agent flow and get out of the way.
                    self?.detailWindow?.close()
                    self?.detailWindow = nil
                    start(task)
                }
            }
        )
        detailWindow = present(view, title: "Task")
    }

    private func present<Content: View>(_ view: Content, title: String) -> NSWindow {
        let hosting = NSHostingController(rootView: view.background(FQTheme.background))
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
