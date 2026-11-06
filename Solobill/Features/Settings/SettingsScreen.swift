import SwiftUI

/// Opened from the Overview toolbar: the workspace name and the Account screen.
struct SettingsScreen: View {
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Loadable { [api] in
                try await api.me()
            } content: { me, reload in
                Form {
                    Section("Workspace") {
                        WorkspaceNameRow(workspace: me.workspace, editable: me.role != .member, saved: reload)
                    }
                    Section {
                        NavigationLink {
                            AccountScreen()
                        } label: {
                            LabeledContent("Account", value: me.email)
                        }
                        .accessibilityIdentifier("settings.account")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct WorkspaceNameRow: View {
    let workspace: Workspace
    let editable: Bool
    let saved: @Sendable () async -> Void

    @Environment(\.api) private var api
    @State private var name: String
    @State private var working = false
    @State private var message: String?

    init(workspace: Workspace, editable: Bool, saved: @escaping @Sendable () async -> Void) {
        self.workspace = workspace
        self.editable = editable
        self.saved = saved
        _name = State(initialValue: workspace.name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        if editable {
            TextField("Workspace name", text: $name)
                .textContentType(.organizationName)
                .submitLabel(.done)
                .onSubmit { Task { await save() } }
                .accessibilityIdentifier("settings.workspaceName")
            if trimmed != workspace.name {
                Button("Save name") { Task { await save() } }
                    .disabled(trimmed.isEmpty || trimmed.count > 120 || working)
                    .accessibilityIdentifier("settings.saveWorkspace")
            }
            if let message {
                Text(message).foregroundStyle(.red)
            }
        } else {
            LabeledContent("Name", value: workspace.name)
        }
    }

    private func save() async {
        guard !trimmed.isEmpty, trimmed != workspace.name else { return }
        working = true
        defer { working = false }
        message = nil
        do {
            _ = try await api.renameWorkspace(trimmed)
            await saved()
        } catch {
            message = error.localizedDescription
        }
    }
}
