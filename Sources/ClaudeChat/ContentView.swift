import SwiftUI
import AppKit

@MainActor
struct ContentView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if store.apiKey.isEmpty {
                WelcomeView()
            } else if let id = store.selectedID {
                ChatView(conversationID: id)
                    .id(id)
            } else {
                Text("No chat selected")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sidebar

@MainActor
struct Sidebar: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            List(selection: $store.selectedID) {
                ForEach(store.sortedConversations) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title)
                            .lineLimit(1)
                        Text("\(ModelOption.find(c.modelID).name) · \(Fmt.money(c.totalCost))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Delete Chat", role: .destructive) { store.delete(c.id) }
                    }
                }
            }
            Divider()
            CreditMeter()
                .padding(12)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.newConversation()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New chat (⌘N)")
            }
        }
    }
}

@MainActor
struct CreditMeter: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        let fraction = store.startingCredit > 0
            ? min(max(store.remainingCredit / store.startingCredit, 0), 1)
            : 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Credit left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.money(store.remainingCredit))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            ProgressView(value: fraction)
                .tint(fraction < 0.15 ? Color.red : Color.accentColor)
            Text("Spent \(Fmt.money(store.totalSpent)) of \(Fmt.money(store.startingCredit)) (estimate)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - First run

@MainActor
struct WelcomeView: View {
    @Environment(ChatStore.self) private var store
    @State private var keyDraft = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Connect your Claude API key")
                .font(.title2.weight(.semibold))
            Text("Create a key in the Claude Console under API Keys, then paste it here. It's stored in your Mac's Keychain, and your $100 of credit is spent only as you chat.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack {
                SecureField("sk-ant-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Link("Open the Claude Console", destination: URL(string: "https://platform.claude.com")!)
                .font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() {
        guard !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.setAPIKey(keyDraft)
        keyDraft = ""
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
