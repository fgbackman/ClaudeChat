import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @State private var keyDraft = ""
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("API key") {
                SecureField("Paste a new key (sk-ant-…)", text: $keyDraft)
                HStack {
                    Button("Save Key") {
                        store.setAPIKey(keyDraft)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    if store.apiKey.isEmpty {
                        Text("No key saved").foregroundStyle(.secondary)
                    } else {
                        Text("Saved key ends in …\(String(store.apiKey.suffix(4)))")
                            .foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { store.setAPIKey("") }
                    }
                }
            }

            Section {
                TextField("Starting credit ($)", value: $store.startingCredit, format: .number)
                LabeledContent("Spent so far (estimate)", value: Fmt.money(store.totalSpent))
                LabeledContent("Left", value: Fmt.money(store.remainingCredit))
                Button("Reset Spent to $0…") { confirmReset = true }
            } header: {
                Text("Credit tracking")
            } footer: {
                Text("Worked out from the token counts the API reports and the published per-token prices. The Claude Console's usage and billing pages are the real record.")
                    .foregroundStyle(.secondary)
            }

            Section("Replies") {
                Picker("Default model", selection: $store.defaultModelID) {
                    ForEach(ModelOption.all) { m in
                        Text("\(m.name): \(m.blurb)").tag(m.id)
                    }
                }
                Picker("Effort", selection: $store.effort) {
                    ForEach(Effort.allCases) { e in
                        Text(e.label).tag(e)
                    }
                }
                Stepper("Max reply length: \(store.maxTokens.formatted()) tokens",
                        value: $store.maxTokens, in: 1_000...64_000, step: 1_000)
                Toggle("Show Claude's reasoning (summarized)", isOn: $store.showThinking)
                Toggle("Prompt caching (makes long chats much cheaper)", isOn: $store.useCache)
            }

            Section {
                TextEditor(text: $store.systemPrompt)
                    .font(.body)
                    .frame(minHeight: 90)
            } header: {
                Text("System prompt")
            } footer: {
                Text("Optional standing instructions sent with every message, e.g. \"Call me Fred. Keep answers short.\"")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .confirmationDialog("Reset the spending counter to $0?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.totalSpent = 0 }
        }
    }
}
