import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class ChatStore {
    var conversations: [Conversation] = []
    var selectedID: UUID?
    var isStreaming = false
    var apiKey: String = ""
    var pendingAttachments: [Attachment] = []
    var attachmentError: String?

    // Settings, persisted in UserDefaults
    var defaultModelID: String { didSet { defaults.set(defaultModelID, forKey: "defaultModelID") } }
    var effort: Effort { didSet { defaults.set(effort.rawValue, forKey: "effort") } }
    var showThinking: Bool { didSet { defaults.set(showThinking, forKey: "showThinking") } }
    var useCache: Bool { didSet { defaults.set(useCache, forKey: "useCache") } }
    var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: "systemPrompt") } }
    var maxTokens: Int { didSet { defaults.set(maxTokens, forKey: "maxTokens") } }
    var startingCredit: Double { didSet { defaults.set(startingCredit, forKey: "startingCredit") } }
    var totalSpent: Double { didSet { defaults.set(totalSpent, forKey: "totalSpent") } }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        defaultModelID = d.string(forKey: "defaultModelID") ?? ModelOption.fallback.id
        effort = Effort(rawValue: d.string(forKey: "effort") ?? "") ?? .medium
        showThinking = d.object(forKey: "showThinking") as? Bool ?? false
        useCache = d.object(forKey: "useCache") as? Bool ?? true
        systemPrompt = d.string(forKey: "systemPrompt") ?? ""
        maxTokens = d.object(forKey: "maxTokens") as? Int ?? 16_000
        startingCredit = d.object(forKey: "startingCredit") as? Double ?? 100
        totalSpent = d.double(forKey: "totalSpent")
        apiKey = Keychain.load() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""

        load()
        if conversations.isEmpty {
            newConversation()
        } else {
            selectedID = sortedConversations.first?.id
        }
    }

    // MARK: Derived

    var remainingCredit: Double { startingCredit - totalSpent }
    var sortedConversations: [Conversation] { conversations.sorted { $0.updatedAt > $1.updatedAt } }

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    // MARK: Conversations

    func newConversation() {
        if let id = selectedID, let i = index(of: id), conversations[i].messages.isEmpty {
            conversations[i].modelID = defaultModelID
            return   // reuse the empty chat that's already open
        }
        let c = Conversation(modelID: defaultModelID)
        conversations.append(c)
        selectedID = c.id
        save()
    }

    func delete(_ id: UUID) {
        if isStreaming && selectedID == id { stop() }
        if let i = index(of: id) {
            for m in conversations[i].messages {
                m.attachments.forEach(AttachmentStore.delete)
            }
        }
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = sortedConversations.first?.id }
        if conversations.isEmpty { newConversation() }
        save()
    }

    func setModel(_ modelID: String, for cid: UUID) {
        guard let i = index(of: cid) else { return }
        conversations[i].modelID = modelID
        defaultModelID = modelID
        save()
    }

    func setAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { Keychain.delete() } else { Keychain.save(k) }
        apiKey = k
    }

    // MARK: Attachments waiting to be sent

    func addAttachments(_ urls: [URL]) {
        attachmentError = nil
        var problems: [String] = []
        for url in urls {
            do {
                pendingAttachments.append(try AttachmentStore.make(from: url))
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty { attachmentError = problems.joined(separator: "\n") }
    }

    func addImage(_ image: NSImage, name: String = "Pasted image") {
        attachmentError = nil
        do {
            pendingAttachments.append(try AttachmentStore.make(fromImage: image, name: name))
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    /// ⌘⇧V: attach copied files or a copied image (e.g. a screenshot taken with ⌃⇧⌘4).
    func attachFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addAttachments(urls)
        } else if let image = NSImage(pasteboard: pb) {
            addImage(image)
        } else {
            attachmentError = "There's no image or file on the clipboard."
        }
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose pictures, PDFs or text files to send to Claude"
        panel.prompt = "Attach"
        if panel.runModal() == .OK { addAttachments(panel.urls) }
    }

    func removePending(_ id: UUID) {
        if let a = pendingAttachments.first(where: { $0.id == id }) { AttachmentStore.delete(a) }
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: Sending

    /// Sends a message. Pass `includePending: true` to send the attachments waiting in the composer.
    func send(_ raw: String, includePending: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = includePending ? pendingAttachments : []
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming, !apiKey.isEmpty,
              let cid = selectedID, let i = index(of: cid) else { return }

        let model = ModelOption.find(conversations[i].modelID)
        var history = conversations[i].messages
        history.append(ChatMessage(role: .user, text: text, attachments: attachments))
        let request = MessageRequest(
            model: model.id,
            system: systemPrompt,
            messages: Self.apiMessages(history),
            maxTokens: maxTokens,
            effort: effort,
            showThinking: showThinking,
            useCache: useCache
        )
        guard let body = try? JSONSerialization.data(withJSONObject: AnthropicClient.body(for: request)) else {
            attachmentError = "Couldn't prepare the message."
            return
        }
        guard body.count <= AnthropicClient.maxRequestBytes else {
            attachmentError = "This chat plus its attachments is over the API's 32 MB request limit. Remove an attachment or start a new chat (⌘N)."
            return
        }

        if includePending { pendingAttachments = [] }
        attachmentError = nil
        conversations[i].messages = history
        if conversations[i].title == "New chat" {
            conversations[i].title = Self.makeTitle(text.isEmpty ? (attachments.first?.name ?? "Attachment") : text)
        }
        conversations[i].updatedAt = Date()

        let reply = ChatMessage(role: .assistant, text: "", modelID: model.id)
        let mid = reply.id
        conversations[i].messages.append(reply)

        let key = apiKey
        isStreaming = true
        streamTask = Task {
            var usage = Usage()
            do {
                for try await event in AnthropicClient.stream(body: body, apiKey: key) {
                    switch event {
                    case .text(let t):
                        update(cid, mid) { $0.text += t }
                    case .thinking(let t):
                        update(cid, mid) { $0.thinking += t }
                    case .usage(let u):
                        usage = u
                        update(cid, mid) { $0.usage = u; $0.cost = model.cost(u) }
                    case .stop(let reason):
                        if reason == "max_tokens" {
                            update(cid, mid) { $0.error = "Reply hit the max length limit. Raise it in Settings (⌘,) if you need longer answers." }
                        } else if reason == "refusal" {
                            update(cid, mid) { $0.error = "Claude declined to continue this reply." }
                        }
                    }
                }
                if Task.isCancelled {
                    update(cid, mid) { if $0.text.isEmpty { $0.error = "Stopped." } }
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                let message = error.localizedDescription
                update(cid, mid) { m in
                    if !cancelled {
                        m.error = message
                    } else if m.text.isEmpty {
                        m.error = "Stopped."
                    }
                }
            }
            totalSpent += model.cost(usage)
            isStreaming = false
            streamTask = nil
            save()
        }
    }

    func stop() {
        streamTask?.cancel()
    }

    private func update(_ cid: UUID, _ mid: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = index(of: cid),
              let j = conversations[i].messages.firstIndex(where: { $0.id == mid }) else { return }
        change(&conversations[i].messages[j])
    }

    /// Turns the visible chat into alternating user/assistant API messages with content blocks.
    /// Attachments go before the text of their message, which is how Claude reads them best.
    static func apiMessages(_ msgs: [ChatMessage]) -> [[String: Any]] {
        var turns: [(role: Role, blocks: [[String: Any]])] = []
        for m in msgs {
            var blocks: [[String: Any]] = []
            if m.role == .user {
                for a in m.attachments { blocks.append(contentsOf: AttachmentStore.blocks(for: a)) }
            }
            if !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(["type": "text", "text": m.text])
            }
            if blocks.isEmpty { continue }
            if let last = turns.last, last.role == m.role {
                turns[turns.count - 1].blocks.append(contentsOf: blocks)
            } else {
                turns.append((role: m.role, blocks: blocks))
            }
        }
        while turns.first?.role == .assistant { turns.removeFirst() }
        return turns.map { ["role": $0.role.rawValue, "content": $0.blocks] }
    }

    static func makeTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }

    // MARK: Persistence (~/Library/Application Support/ClaudeChat/conversations.json)

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("ClaudeChat: save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = saved
    }
}
