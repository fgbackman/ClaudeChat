import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @State private var keyDraft = ""
    @State private var keyNameDraft = ""
    @State private var keyToRemove: APIKeyProfile?
    @State private var confirmReset = false
    @AppStorage(AppearanceKey.style) private var styleRaw = ChatStyle.standard.rawValue
    @AppStorage(AppearanceKey.opacity) private var opacity = 1.0
    @AppStorage(AppearanceKey.color) private var colorRaw = TerminalColor.green.rawValue
    @AppStorage(AppearanceKey.mode) private var modeRaw = SeeThroughMode.fade.rawValue

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Style", selection: $styleRaw) {
                    ForEach(ChatStyle.allCases) { s in
                        Text(s.label).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Terminal text", selection: $colorRaw) {
                    ForEach(TerminalColor.allCases) { c in
                        Text(c.label).tag(c.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(styleRaw != ChatStyle.terminal.rawValue)
                Picker("See-through by", selection: $modeRaw) {
                    ForEach(SeeThroughMode.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("See-through") {
                    HStack {
                        Slider(value: $opacity, in: AppearanceKey.minOpacity...1)
                        Text("\(Int((opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Terminal: monospaced text in your chosen colour on black, in the chat and the sidebar. Fade lowers the whole window's opacity; Blur keeps text sharp and blurs what's behind the window. Shortcuts: ⌥⌘T style, ⌥⌘− / ⌥⌘= see-through.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.keyProfiles.isEmpty {
                    Text(store.apiKey.isEmpty ? "No key saved" : "Using the ANTHROPIC_API_KEY environment variable")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.keyProfiles) { p in
                    HStack(spacing: 8) {
                        Button {
                            store.selectAPIKey(p.id)
                        } label: {
                            Image(systemName: p.id == store.activeKeyID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(p.id == store.activeKeyID ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(p.id == store.activeKeyID ? "In use" : "Use this key")

                        TextField("Name", text: Binding(
                            get: { p.name },
                            set: { store.renameAPIKey(p.id, to: $0) }
                        ))
                        .textFieldStyle(.plain)

                        Text("…\(p.suffix)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            keyToRemove = p
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this key")
                    }
                }
                TextField("Name (optional, e.g. Work)", text: $keyNameDraft)
                SecureField("Paste a key (sk-ant-…)", text: $keyDraft)
                HStack {
                    Spacer()
                    Button("Add Key") {
                        store.setAPIKey(keyDraft, name: keyNameDraft)
                        keyDraft = ""
                        keyNameDraft = ""
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("API keys")
            } footer: {
                Text("The ticked key is used for new replies. Keys are stored in your Mac's Keychain. Each key tracks its own credit and spending, below.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Starting credit ($)", value: $store.startingCredit, format: .number)
                LabeledContent("Spent so far (estimate)", value: Fmt.money(store.totalSpent))
                LabeledContent("Left", value: Fmt.money(store.remainingCredit))
                Button("Reset Spent to $0…") { confirmReset = true }
                if store.keyProfiles.count > 1 {
                    ForEach(store.keyProfiles) { p in
                        LabeledContent(p.name) {
                            Text("\(Fmt.money(p.remaining)) left · \(Fmt.money(p.spent)) spent")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(store.activeKeyName.map { "Credit tracking: \($0)" } ?? "Credit tracking")
            } footer: {
                Text("Shows the key that's in use; with several keys, each one's balance is listed above. Worked out from the token counts the API reports and the published per-token prices. The Claude Console's usage and billing pages are the real record.")
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
        .frame(width: 560, height: 820)
        .confirmationDialog("Remove the key “\(keyToRemove?.name ?? "")”?",
                            isPresented: Binding(get: { keyToRemove != nil },
                                                 set: { if !$0 { keyToRemove = nil } }),
                            presenting: keyToRemove) { p in
            Button("Remove", role: .destructive) { store.removeAPIKey(p.id) }
        } message: { _ in
            Text("It's deleted from your Keychain. You'd need to paste it again to use it.")
        }
        .confirmationDialog("Reset spending to $0 for \(store.activeKeyName ?? "this key")?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.totalSpent = 0 }
        }
    }
}
