import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var auth: FastplayAuthStore
    var initialTab: SettingsTab = .projects
    var onReplayOnboarding: (() -> Void)?

    enum SettingsTab: Hashable {
        case account, projects, tools, chat, general
    }

    @State private var tab: SettingsTab = .projects
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isRegistering = false

    var body: some View {
        TabView(selection: $tab) {
            accountTab
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account)
            projectsTab
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(SettingsTab.projects)
            toolsTab
                .tabItem { Label("Tools", systemImage: "hammer") }
                .tag(SettingsTab.tools)
            chatTab
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(SettingsTab.chat)
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 560, height: 440)
        .onAppear { tab = initialTab }
    }

    private var accountTab: some View {
        Form {
            if auth.isLoggedIn, let user = auth.user {
                Section("Signed in") {
                    LabeledContent("Name", value: user.name)
                    LabeledContent("Email", value: user.email)
                    Button("Sign Out") {
                        Task { await auth.logout() }
                    }
                    .disabled(auth.isBusy)
                }
                Section {
                    Text("⌘B opens Boards for this account — workspaces, projects, and tasks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(isRegistering ? "Create account" : "Sign in to Fastplay") {
                    if isRegistering {
                        TextField("Name", text: $name)
                            .textContentType(.name)
                    }
                    TextField("Email", text: $email)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    if let error = auth.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button(isRegistering ? "Create account" : "Sign in") {
                            Task {
                                if isRegistering {
                                    await auth.register(name: name, email: email, password: password)
                                } else {
                                    await auth.login(email: email, password: password)
                                }
                            }
                        }
                        .disabled(auth.isBusy || email.isEmpty || password.isEmpty || (isRegistering && name.isEmpty))
                        .keyboardShortcut(.defaultAction)

                        if auth.isBusy {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                Section {
                    Button(isRegistering ? "Already have an account? Sign in" : "Need an account? Register") {
                        isRegistering.toggle()
                        auth.lastError = nil
                    }
                    Text("Uses your Fastplay account at web-production-19fc4.up.railway.app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private var projectsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Configured folders")
                    .font(.headline)
                Spacer()
                Button("Add Folder…", action: addFolder)
            }

            if settings.projects.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "folder.badge.plus",
                    description: Text("Add repositories or folders you want agents to open into.")
                )
            } else {
                List {
                    ForEach(settings.projects) { project in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).font(.body.weight(.medium))
                                Text(project.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                settings.removeProject(project)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
    }

    private var toolsTab: some View {
        List {
            ForEach($settings.tools) { $tool in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $tool.enabled) {
                        Label {
                            Text(tool.displayName)
                        } icon: {
                            AgentBrandIcon(kind: tool.kind, size: 14)
                        }
                    }
                    TextField("Command path", text: $tool.commandPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!tool.enabled)
                    Text("Runs as a CLI agent inside Fastq Terminal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(8)
    }

    private var chatTab: some View {
        Form {
            Section("Chat mode (⌘1 in the launcher)") {
                Picker("Provider", selection: $settings.chatProvider) {
                    ForEach(ChatProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            }

            Section("Anthropic") {
                SecureField("API key (sk-ant-…)", text: $settings.anthropicAPIKey)
                Picker("Model", selection: $settings.anthropicChatModel) {
                    ForEach(ChatProvider.anthropic.models, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }

            Section("OpenAI") {
                SecureField("API key (sk-…)", text: $settings.openAIAPIKey)
                Picker("Model", selection: $settings.openAIChatModel) {
                    ForEach(ChatProvider.openai.models, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }

            Section {
                Text("Keys are stored locally in Fastq's preferences and sent only to the provider you select.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private var generalTab: some View {
        Form {
            Section("Defaults") {
                Picker("Default tool", selection: Binding(
                    get: { settings.defaultToolID ?? settings.enabledTools.first?.id },
                    set: { settings.defaultToolID = $0 }
                )) {
                    ForEach(settings.enabledTools) { tool in
                        Text(tool.displayName).tag(Optional(tool.id))
                    }
                }

                Picker("Default model", selection: $settings.defaultModel) {
                    ForEach(AgentModelOption.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
            }

            Section("Launcher") {
                LabeledContent("Hotkey") {
                    HotkeyRecorderButton(
                        keyCode: $settings.hotkeyKeyCode,
                        modifiers: $settings.hotkeyModifiers,
                        onChange: {
                            HotKeyManager.shared.register(
                                keyCode: settings.hotkeyKeyCode,
                                modifiers: settings.hotkeyModifiers
                            )
                        }
                    )
                }
                Text("Press \(HotkeyShortcut.displayString(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)) anywhere to open Fastq.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Setup") {
                if settings.hasCompletedOnboarding {
                    LabeledContent("Onboarding") {
                        Text("Completed")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Onboarding") {
                        Text("Incomplete")
                            .foregroundStyle(.orange)
                    }
                }

                Button("Replay welcome experience…") {
                    settings.resetOnboarding()
                    onReplayOnboarding?()
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private func addFolder() {
        FolderPicker.chooseDirectories { urls in
            for url in urls {
                settings.addProject(path: url.path)
            }
        }
    }
}
