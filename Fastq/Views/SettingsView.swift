import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onReplayOnboarding: (() -> Void)?

    var body: some View {
        TabView {
            projectsTab
                .tabItem { Label("Projects", systemImage: "folder") }
            toolsTab
                .tabItem { Label("Tools", systemImage: "hammer") }
            chatTab
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 420)
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
