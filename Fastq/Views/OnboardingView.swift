import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    var onFinish: () -> Void
    var onOpenLauncher: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var detections: [DetectedToolPath] = []
    @State private var isScanning = false
    @State private var appearLogo = false
    @State private var appearContent = false

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 0) {
                topBar
                stepBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(width: 720, height: 560)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) {
                appearLogo = true
            }
            withAnimation(.easeOut(duration: 0.45).delay(0.12)) {
                appearContent = true
            }
            refreshDetections()
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.32, blue: 0.28))
                    .scaleEffect(appearLogo ? 1 : 0.6)
                    .opacity(appearLogo ? 1 : 0)

                Text("fastq")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(0.4)
            }

            Spacer()

            stepIndicator
        }
        .padding(.bottom, 18)
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { item in
                Capsule()
                    .fill(item == step ? Color.white.opacity(0.9) : Color.white.opacity(0.18))
                    .frame(width: item == step ? 18 : 6, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            }
        }
        .accessibilityLabel("Step \(step.progressIndex + 1) of \(OnboardingStep.allCases.count)")
    }

    @ViewBuilder
    private var stepBody: some View {
        Group {
            switch step {
            case .welcome:
                welcomeStep
            case .projects:
                projectsStep
            case .tools:
                toolsStep
            case .ready:
                readyStep
            }
        }
        .id(step)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
        .opacity(appearContent ? 1 : 0)
        .offset(y: appearContent ? 0 : 10)
    }

    private var bottomBar: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }
                    .buttonStyle(OnboardingGhostButtonStyle())
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }

            Spacer()

            if canSkipCurrent {
                Button("Skip") { goNext() }
                    .buttonStyle(OnboardingGhostButtonStyle())
            }

            Button(primaryTitle) { primaryAction() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(!canContinue)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 18)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 12)

            Text("fastq")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .tracking(-1.2)
                .foregroundStyle(.white)

            Text("Your agent launcher.")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))

            Text("Pick a project, choose Cursor / Claude Code / Codex, and send the prompt — then jump back to any live agent from one place.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                HotkeyPill(keys: [hotkeyLabel])
                Text("opens Fastq from anywhere")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projectsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(
                title: "Add the repos you live in",
                subtitle: "Fastq launches agents into these folders. You can add more anytime in Settings."
            )

            Button(action: addFolders) {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28, weight: .light))
                    Text(settings.projects.isEmpty ? "Drop in project folders" : "Add another folder")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Click to browse — add as many as you need")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                        .foregroundStyle(Color.white.opacity(0.22))
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                )
            }
            .buttonStyle(.plain)

            if !settings.projects.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(settings.projects) { project in
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color(red: 0.95, green: 0.42, blue: 0.28))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(project.path)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        settings.removeProject(project)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            Spacer(minLength: 0)
        }
    }

    private var toolsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                stepHeading(
                    title: "Choose your agents",
                    subtitle: "We scanned your Mac for installed CLIs. Turn on the ones you use."
                )
                Spacer(minLength: 12)
                Button {
                    refreshDetections(animated: true)
                } label: {
                    Label(isScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(OnboardingGhostButtonStyle())
                .disabled(isScanning)
            }

            VStack(spacing: 0) {
                ForEach($settings.tools) { $tool in
                    let detection = detections.first(where: { $0.kind == tool.kind })
                    ToolOnboardingRow(
                        tool: $tool,
                        isDetected: detection?.isInstalled ?? false,
                        detectedPath: detection?.path,
                        isDefault: settings.defaultToolID == tool.id,
                        onMakeDefault: {
                            settings.defaultToolID = tool.id
                        }
                    )
                    if tool.id != settings.tools.last?.id {
                        Divider()
                            .opacity(0.12)
                            .padding(.leading, 52)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            Spacer(minLength: 0)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 8)

            Text("You’re ready.")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .tracking(-0.6)

            VStack(alignment: .leading, spacing: 12) {
                ReadyRow(icon: "folder.fill", text: readinessProjectsLine)
                ReadyRow(icon: "hammer.fill", text: readinessToolsLine)
                ReadyRow(icon: "keyboard", text: "Press \(hotkeyLabel) anytime to open Fastq")
            }
            .padding(.top, 4)

            Text("Agents run inside Fastq — jump back to any live session without hunting windows.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440, alignment: .leading)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func stepHeading(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .projects where settings.projects.isEmpty: return "Add folders"
        case .ready: return "Open Fastq"
        default: return "Continue"
        }
    }

    private var canSkipCurrent: Bool {
        step == .projects
    }

    private var hotkeyLabel: String {
        HotkeyShortcut.displayString(
            keyCode: settings.hotkeyKeyCode,
            modifiers: settings.hotkeyModifiers
        )
    }

    private var canContinue: Bool {
        switch step {
        case .welcome, .projects, .ready:
            return true
        case .tools:
            return !settings.enabledTools.isEmpty
        }
    }

    private var readinessProjectsLine: String {
        let count = settings.projects.count
        if count == 0 { return "No projects yet — add some from Settings" }
        if count == 1 { return "1 project ready: \(settings.projects[0].name)" }
        return "\(count) projects ready"
    }

    private var readinessToolsLine: String {
        let names = settings.enabledTools.map(\.displayName)
        if names.isEmpty { return "No tools enabled" }
        return names.joined(separator: " · ")
    }

    private func primaryAction() {
        switch step {
        case .ready:
            settings.completeOnboarding()
            onOpenLauncher()
            onFinish()
        case .projects where settings.projects.isEmpty:
            addFolders()
        default:
            goNext()
        }
    }

    private func goNext() {
        guard let next = step.next else {
            settings.completeOnboarding()
            onFinish()
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            step = next
        }
        if next == .tools {
            refreshDetections(animated: true)
        }
    }

    private func goBack() {
        guard let previous = step.previous else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            step = previous
        }
    }

    private func addFolders() {
        FolderPicker.chooseDirectories { urls in
            guard !urls.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                for url in urls {
                    settings.addProject(path: url.path)
                }
            }
        }
    }

    private func refreshDetections(animated: Bool = false) {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ToolPathDetector.detectAll()
            DispatchQueue.main.async {
                detections = found
                settings.applyDetectedToolPaths(found)
                isScanning = false
                if animated {
                    withAnimation(.easeOut(duration: 0.25)) {}
                }
            }
        }
    }
}

// MARK: - Subviews

private struct ToolOnboardingRow: View {
    @Binding var tool: ToolConfig
    var isDetected: Bool
    var detectedPath: String?
    var isDefault: Bool
    var onMakeDefault: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AgentBrandIcon(kind: tool.kind, size: 18)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(tool.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if isDefault {
                        Text("Default")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                    }
                }
                Text(statusLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isDetected ? Color.green.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if tool.enabled, !isDefault {
                Button("Set default", action: onMakeDefault)
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Toggle("", isOn: $tool.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(tool.enabled ? 1 : 0.55)
    }

    private var statusLine: String {
        if let detectedPath {
            return detectedPath
        }
        return "Not detected — install the CLI, or set the path in Settings"
    }
}

private struct ReadyRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color(red: 0.95, green: 0.36, blue: 0.28))
                .frame(width: 20)
            Text(text)
                .font(.system(size: 14, weight: .medium))
        }
    }
}

private struct HotkeyPill: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

private struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08)
            LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.10, blue: 0.14).opacity(0.45),
                    Color.clear
                ],
                startPoint: .topTrailing,
                endPoint: UnitPoint(x: 0.4, y: 0.55)
            )
            RadialGradient(
                colors: [
                    Color(red: 0.85, green: 0.25, blue: 0.2).opacity(0.14),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 320
            )
        }
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black.opacity(isEnabled ? 0.9 : 0.4))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 0.92) : 0.25))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct OnboardingGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}
