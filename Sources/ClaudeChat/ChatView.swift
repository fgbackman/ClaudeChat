import SwiftUI

@MainActor
struct ChatView: View {
    @Environment(ChatStore.self) private var store
    let conversationID: UUID

    @State private var draft = ""
    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool

    private var conversation: Conversation? {
        store.conversations.first { $0.id == conversationID }
    }

    private var model: ModelOption {
        ModelOption.find(conversation?.modelID ?? store.defaultModelID)
    }

    var body: some View {
        @Bindable var bstore = store
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if conversation?.messages.isEmpty ?? true {
                            EmptyChatHint(model: model, effort: store.effort)
                        }
                        ForEach(conversation?.messages ?? []) { m in
                            MessageRow(message: m)
                                .id(m.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: conversation?.messages.last?.text) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: conversation?.messages.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            composer
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            store.addAttachments(files)
            composerFocused = true
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .navigationTitle(conversation?.title ?? "Claude")
        .navigationSubtitle("\(model.name) · this chat \(Fmt.money(conversation?.totalCost ?? 0))")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(ModelOption.all) { m in
                        Button {
                            store.setModel(m.id, for: conversationID)
                        } label: {
                            if m.id == model.id {
                                Label("\(m.name): \(m.blurb)", systemImage: "checkmark")
                            } else {
                                Text("\(m.name): \(m.blurb)")
                            }
                        }
                    }
                } label: {
                    Text(model.name)
                }
                .fixedSize()
                .help(model.blurb)

                Picker("Effort", selection: $bstore.effort) {
                    ForEach(Effort.allCases) { e in
                        Text(e.label).tag(e)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Effort: lower means fewer tokens, so cheaper and faster replies")
            }
        }
        .onAppear { composerFocused = true }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pendingAttachments.isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = store.attachmentError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(err)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        store.attachmentError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.callout)
                .foregroundStyle(.red)
            }

            if !store.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.pendingAttachments) { a in
                            PendingAttachmentChip(attachment: a) {
                                store.removePending(a.id)
                            }
                        }
                    }
                }
            }

            composerRow
        }
        .padding(12)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                Button("Choose Files…") { store.chooseAttachments() }
                Button("Paste Image or File from Clipboard  ⌘⇧V") { store.attachFromClipboard() }
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 18))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.bottom, 9)
            .help("Attach pictures, PDFs or text files (or drag them here)")

            TextField("Message Claude…  (Return to send, ⌥Return for a new line)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($composerFocused)
                .onSubmit(send)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))

            if store.isStreaming {
                Button {
                    store.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(!canSend)
                .help("Send")
            }
        }
    }

    private func send() {
        guard !store.isStreaming, canSend else { return }
        let text = draft
        draft = ""
        store.send(text, includePending: true)
    }
}

@MainActor
struct PendingAttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let img = AttachmentStore.thumbnail(for: attachment) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: attachment.symbol)
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

@MainActor
struct EmptyChatHint: View {
    let model: ModelOption
    let effort: Effort

    var body: some View {
        // A typical short exchange: ~1,000 tokens in, ~800 out (thinking included).
        let typical = model.cost(Usage(inputTokens: 1_000, outputTokens: 800))
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("New chat with \(model.name)")
                .font(.title3.weight(.semibold))
            Text(model.blurb)
                .foregroundStyle(.secondary)
            Text("A short back-and-forth costs roughly \(Fmt.money(typical)) per reply. Longer chats cost more, because the whole conversation is sent each time.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
