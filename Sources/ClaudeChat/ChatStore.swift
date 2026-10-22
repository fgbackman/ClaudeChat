import Foundation
import AppKit
import Observation

/// A saved API key. Only the label and last four characters are stored here;
/// the key itself is in the Keychain under `id`.
/// Each key also has its own credit budget and running spend estimate.
struct APIKeyProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var suffix: String
    var startingCredit: Double = 100
    var spent: Double = 0

    var remaining: Double { startingCredit - spent }

    init(id: String, name: String, suffix: String, startingCredit: Double = 100, spent: Double = 0) {
        self.id = id
        self.name = name
        self.suffix = suffix
        self.startingCredit = startingCredit
        self.spent = spent
    }

    // Keys saved before credit was tracked per key have no budget fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        suffix = try c.decode(String.self, forKey: .suffix)
        startingCredit = try c.decodeIfPresent(Double.self, forKey: .startingCredit) ?? 100
        spent = try c.decodeIfPresent(Double.self, forKey: .spent) ?? 0
    }
}

@MainActor
@Observable
final class ChatStore {
    var conversations: [Conversation] = []
    /// The chat in the most recently focused tab; the menu bar panel follows it.
    var selectedID: UUID?
    /// The active key's secret. Use `keyProfiles` / `activeKeyID` to manage the saved keys.
    var apiKey: String = ""
    var keyProfiles: [APIKeyProfile] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(keyProfiles) { defaults.set(data, forKey: "keyProfiles") }
        }
    }
    var activeKeyID: String? { didSet { defaults.set(activeKeyID, forKey: "activeKeyID") } }
    /// Chats with a reply streaming in right now. Each tab can run its own.
    var streaming: Set<UUID> = []
    /// Attachments waiting in each chat's composer, and the last attachment/send problem per chat.
    var pending: [UUID: [Attachment]] = [:]
    var attachmentErrors: [UUID: String] = [:]
    @ObservationIgnored var openedFirstWindow = false

    // Settings, persisted in UserDefaults
    var defaultModelID: String { didSet { defaults.set(defaultModelID, forKey: "defaultModelID") } }
    var effort: Effort { didSet { defaults.set(effort.rawValue, forKey: "effort") } }
    var showThinking: Bool { didSet { defaults.set(showThinking, forKey: "showThinking") } }
    var useCache: Bool { didSet { defaults.set(useCache, forKey: "useCache") } }
    var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: "systemPrompt") } }
    var maxTokens: Int { didSet { defaults.set(maxTokens, forKey: "maxTokens") } }
    /// Credit numbers used only when no saved key exists (e.g. ANTHROPIC_API_KEY from the environment),
    /// and the source for migrating the old single counter to the first key.
    var fallbackCredit: Double { didSet { defaults.set(fallbackCredit, forKey: "startingCredit") } }
    var fallbackSpent: Double { didSet { defaults.set(fallbackSpent, forKey: "totalSpent") } }

    // Credit tracking follows the active key.
    private var activeIndex: Int? { keyProfiles.firstIndex { $0.id == activeKeyID } }

    var startingCredit: Double {
        get { activeIndex.map { keyProfiles[$0].startingCredit } ?? fallbackCredit }
        set { if let i = activeIndex { keyProfiles[i].startingCredit = newValue } else { fallbackCredit = newValue } }
    }
    var totalSpent: Double {
        get { activeIndex.map { keyProfiles[$0].spent } ?? fallbackSpent }
        set { if let i = activeIndex { keyProfiles[i].spent = newValue } else { fallbackSpent = newValue } }
    }

    /// Charges a cost to the key that made the request, even if another key is active by now.
    func addSpend(_ amount: Double, keyID: String?) {
        if let id = keyID, let i = keyProfiles.firstIndex(where: { $0.id == id }) {
            keyProfiles[i].spent += amount
        } else {
            fallbackSpent += amount
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var streamTasks: [UUID: Task<Void, Never>] = [:]
    /// Tool rounds allowed in one reply before stopping, so a confused run can't spend without limit.
    static let maxToolRounds = 60

    init() {
        let d = UserDefaults.standard
        defaultModelID = d.string(forKey: "defaultModelID") ?? ModelOption.fallback.id
        effort = Effort(rawValue: d.string(forKey: "effort") ?? "") ?? .medium
        showThinking = d.object(forKey: "showThinking") as? Bool ?? false
        useCache = d.object(forKey: "useCache") as? Bool ?? true
        systemPrompt = d.string(forKey: "systemPrompt") ?? ""
        maxTokens = d.object(forKey: "maxTokens") as? Int ?? 16_000
        fallbackCredit = d.object(forKey: "startingCredit") as? Double ?? 100
        fallbackSpent = d.double(forKey: "totalSpent")
        loadKeys()

        load()
        // Chats left empty by closed tabs are dropped at launch.
        conversations.removeAll { $0.messages.isEmpty && $0.projectPath == nil }
        if conversations.isEmpty {
            newConversation()
        } else {
            selectedID = sortedConversations.first?.id
        }
    }

    // MARK: Derived

    var remainingCredit: Double { startingCredit - totalSpent }
    var sortedConversations: [Conversation] { conversations.sorted { $0.updatedAt > $1.updatedAt } }

    func isStreaming(_ id: UUID?) -> Bool { id.map { streaming.contains($0) } ?? false }
    func conversation(_ id: UUID?) -> Conversation? { id.flatMap { id in conversations.first { $0.id == id } } }

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    // MARK: Conversations

    /// Starts a chat and returns its ID. Pass the chat a tab is showing to reuse it if it's still empty.
    @discardableResult
    func newConversation(replacing current: UUID? = nil) -> UUID {
        if let id = current, let i = index(of: id), conversations[i].messages.isEmpty, !isStreaming(id) {
            conversations[i].modelID = defaultModelID
            selectedID = id
            return id   // reuse the empty chat that's already open
        }
        let c = Conversation(modelID: defaultModelID)
        conversations.append(c)
        selectedID = c.id
        save()
        return c.id
    }

    func delete(_ id: UUID) {
        stop(id)
        pending[id]?.forEach(AttachmentStore.delete)
        pending[id] = nil
        if let i = index(of: id) {
            for m in conversations[i].messages {
                m.attachments.forEach(AttachmentStore.delete)
            }
        }
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { newConversation() }
        if selectedID == id { selectedID = sortedConversations.first?.id }
        save()
    }

    // MARK: Projects

    func setProject(_ folder: URL?, name: String?, for cid: UUID) {
        guard let i = index(of: cid) else { return }
        conversations[i].projectPath = folder?.path
        conversations[i].projectName = name
        if let name, conversations[i].messages.isEmpty, conversations[i].title == "New chat" {
            conversations[i].title = name.split(separator: "/").last.map(String.init) ?? name
        }
        save()
    }

    func setModel(_ modelID: String, for cid: UUID) {
        guard let i = index(of: cid) else { return }
        conversations[i].modelID = modelID
        defaultModelID = modelID
        save()
    }

    // MARK: API keys

    /// Adds a key (named, or "Key N" if no name is given) and makes it the active one.
    /// An empty key removes the active one, which is what the old single-key UI expected.
    func setAPIKey(_ key: String, name: String = "") {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty {
            if let id = activeKeyID { removeAPIKey(id) }
            return
        }
        let id = UUID().uuidString
        guard Keychain.save(k, account: id) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        keyProfiles.append(APIKeyProfile(id: id,
                                         name: n.isEmpty ? "Key \(keyProfiles.count + 1)" : n,
                                         suffix: String(k.suffix(4))))
        selectAPIKey(id)
    }

    func selectAPIKey(_ id: String) {
        guard keyProfiles.contains(where: { $0.id == id }) else { return }
        activeKeyID = id
        refreshActiveKey()
    }

    func renameAPIKey(_ id: String, to name: String) {
        guard let i = keyProfiles.firstIndex(where: { $0.id == id }) else { return }
        keyProfiles[i].name = name
    }

    func removeAPIKey(_ id: String) {
        Keychain.delete(account: id)
        keyProfiles.removeAll { $0.id == id }
        if activeKeyID == id { activeKeyID = keyProfiles.first?.id }
        refreshActiveKey()
    }

    var activeKeyName: String? { keyProfiles.first { $0.id == activeKeyID }?.name }

    /// `apiKey` is always the active key's secret (or the ANTHROPIC_API_KEY variable if none are saved).
    private func refreshActiveKey() {
        if let id = activeKeyID, let k = Keychain.load(account: id) {
            apiKey = k
        } else if keyProfiles.isEmpty {
            apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        } else {
            apiKey = ""
        }
    }

    private func loadKeys() {
        if let data = defaults.data(forKey: "keyProfiles"),
           let saved = try? JSONDecoder().decode([APIKeyProfile].self, from: data) {
            keyProfiles = saved
        }
        // The single key saved by earlier versions becomes the first entry.
        if keyProfiles.isEmpty, let old = Keychain.load() {
            keyProfiles = [APIKeyProfile(id: "default", name: "Default", suffix: String(old.suffix(4)))]
        }
        let saved = defaults.string(forKey: "activeKeyID")
        activeKeyID = keyProfiles.contains { $0.id == saved } ? saved : keyProfiles.first?.id
        // One-time: the old shared budget and spend move to the key that was in use.
        if !defaults.bool(forKey: "creditPerKeyMigrated") {
            for i in keyProfiles.indices { keyProfiles[i].startingCredit = fallbackCredit }
            if let i = activeIndex { keyProfiles[i].spent = fallbackSpent }
            defaults.set(true, forKey: "creditPerKeyMigrated")
        }
        refreshActiveKey()
    }

    // MARK: Attachments waiting to be sent

    func addAttachments(_ urls: [URL], to cid: UUID) {
        attachmentErrors[cid] = nil
        var problems: [String] = []
        for url in urls {
            do {
                pending[cid, default: []].append(try AttachmentStore.make(from: url))
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty { attachmentErrors[cid] = problems.joined(separator: "\n") }
    }

    func addImage(_ image: NSImage, name: String = "Pasted image", to cid: UUID) {
        attachmentErrors[cid] = nil
        do {
            pending[cid, default: []].append(try AttachmentStore.make(fromImage: image, name: name))
        } catch {
            attachmentErrors[cid] = error.localizedDescription
        }
    }

    /// ⌘⇧V: attach copied files or a copied image (e.g. a screenshot taken with ⌃⇧⌘4).
    func attachFromClipboard(to cid: UUID) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addAttachments(urls, to: cid)
        } else if let image = NSImage(pasteboard: pb) {
            addImage(image, to: cid)
        } else {
            attachmentErrors[cid] = "There's no image or file on the clipboard."
        }
    }

    func chooseAttachments(for cid: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose pictures, PDFs or text files to send to Claude"
        panel.prompt = "Attach"
        if panel.runModal() == .OK { addAttachments(panel.urls, to: cid) }
    }

    func removePending(_ id: UUID, from cid: UUID) {
        if let a = pending[cid]?.first(where: { $0.id == id }) { AttachmentStore.delete(a) }
        pending[cid]?.removeAll { $0.id == id }
    }

    // MARK: Sending

    /// Sends a message in chat `cid` (default: the most recently focused one).
    /// Pass `includePending: true` to send the attachments waiting in that chat's composer.
    func send(_ raw: String, in cid: UUID? = nil, includePending: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cid = cid ?? selectedID, let i = index(of: cid) else { return }
        let attachments = includePending ? (pending[cid] ?? []) : []
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming(cid), !apiKey.isEmpty else { return }

        let model = ModelOption.find(conversations[i].modelID)
        var history = conversations[i].messages
        history.append(ChatMessage(role: .user, text: text, attachments: attachments))

        // A chat linked to a project gets file tools and a note about the project.
        var tools: ProjectTools?
        var system = systemPrompt
        if let root = conversations[i].projectURL {
            guard FileManager.default.fileExists(atPath: root.path) else {
                attachmentErrors[cid] = "The project folder \(root.path) is missing. Pick the project again from the Project menu."
                return
            }
            tools = ProjectTools(root: root)
            let note = ProjectTools.systemPrompt(name: conversations[i].projectName ?? root.lastPathComponent, root: root)
            system = system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note : system + "\n\n" + note
        }
        let baseMessages = Self.apiMessages(history)
        func makeBody(_ turns: [[String: Any]]) -> Data? {
            let request = MessageRequest(
                model: model.id,
                system: system,
                messages: Self.merge(baseMessages, turns),
                maxTokens: maxTokens,
                effort: effort,
                showThinking: showThinking,
                useCache: useCache,
                tools: tools == nil ? [] : ProjectTools.definitions
            )
            return try? JSONSerialization.data(withJSONObject: AnthropicClient.body(for: request))
        }
        guard let firstBody = makeBody([]) else {
            attachmentErrors[cid] = "Couldn't prepare the message."
            return
        }
        guard firstBody.count <= AnthropicClient.maxRequestBytes else {
            attachmentErrors[cid] = "This chat plus its attachments is over the API's 32 MB request limit. Remove an attachment or start a new chat (⌘N)."
            return
        }

        if includePending { pending[cid] = nil }
        attachmentErrors[cid] = nil
        conversations[i].messages = history
        if conversations[i].title == "New chat" {
            conversations[i].title = Self.makeTitle(text.isEmpty ? (attachments.first?.name ?? "Attachment") : text)
        }
        conversations[i].updatedAt = Date()

        let reply = ChatMessage(role: .assistant, text: "", modelID: model.id)
        let mid = reply.id
        conversations[i].messages.append(reply)

        let key = apiKey
        let keyID = activeKeyID   // spending is charged to this key, even if you switch mid-reply
        streaming.insert(cid)
        streamTasks[cid] = Task {
            var turns: [[String: Any]] = []   // this reply's assistant turns and tool results
            var spent = Usage()               // usage of finished rounds
            var spentCost = 0.0               // and what they cost
            var roundUsage = Usage()          // the round streaming now (billed even if stopped partway)
            var round = 0
            do {
                while true {
                    round += 1
                    guard let body = round == 1 ? firstBody : makeBody(turns) else {
                        throw APIError(message: "Couldn't prepare the next request.")
                    }
                    var blocks: [[String: Any]] = []
                    roundUsage = Usage()
                    var stopReason = ""
                    var startedText = false
                    for try await event in AnthropicClient.stream(body: body, apiKey: key) {
                        switch event {
                        case .text(let t):
                            update(cid, mid) { m in
                                if !startedText && !m.text.isEmpty { m.text += "\n\n" }
                                m.text += t
                            }
                            startedText = true
                        case .thinking(let t):
                            update(cid, mid) { $0.thinking += t }
                        case .usage(let u):
                            roundUsage = u
                            let total = spent + u
                            let cost = spentCost + model.cost(u)   // priced per request: long-prompt rates apply per call
                            update(cid, mid) { $0.usage = total; $0.cost = cost }
                        case .block(let b):
                            blocks.append(b)
                        case .stop(let reason):
                            stopReason = reason
                            if reason == "max_tokens" {
                                update(cid, mid) { $0.error = "Reply hit the max length limit. Raise it in Settings (⌘,) if you need longer answers." }
                            } else if reason == "refusal" {
                                update(cid, mid) { $0.error = "Claude declined to continue this reply." }
                            }
                        }
                    }
                    spent = spent + roundUsage
                    spentCost += model.cost(roundUsage)
                    addSpend(model.cost(roundUsage), keyID: keyID)
                    roundUsage = Usage()

                    let calls = blocks.filter { ($0["type"] as? String) == "tool_use" }
                    guard stopReason == "tool_use", let tools, !calls.isEmpty, !Task.isCancelled else {
                        // Unanswered tool calls would break the next request, so drop them.
                        let kept = blocks.filter { ($0["type"] as? String) != "tool_use" }
                        if !kept.isEmpty { turns.append(["role": "assistant", "content": kept]) }
                        break
                    }

                    var results: [[String: Any]] = []
                    for call in calls {
                        let id = (call["id"] as? String) ?? UUID().uuidString
                        let name = (call["name"] as? String) ?? "tool"
                        let input = (call["input"] as? [String: Any]) ?? [:]
                        update(cid, mid) { $0.toolSteps.append(ToolStep(id: id, title: Self.stepTitle(name, input))) }
                        let out = await tools.run(name, input)
                        update(cid, mid) { m in
                            if let k = m.toolSteps.firstIndex(where: { $0.id == id }) {
                                m.toolSteps[k].title = out.title
                                m.toolSteps[k].detail = out.detail
                                m.toolSteps[k].isError = out.isError
                                m.toolSteps[k].done = true
                            }
                        }
                        var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": out.text]
                        if out.isError { result["is_error"] = true }
                        results.append(result)
                    }
                    turns.append(["role": "assistant", "content": blocks])
                    turns.append(["role": "user", "content": results])
                    saveTurns(turns, cid, mid)

                    if Task.isCancelled { break }
                    if round >= Self.maxToolRounds {
                        update(cid, mid) { $0.error = "Stopped after \(Self.maxToolRounds) tool steps. Send \"continue\" to keep going." }
                        break
                    }
                }
                if Task.isCancelled {
                    update(cid, mid) { if $0.text.isEmpty && $0.toolSteps.isEmpty { $0.error = "Stopped." } }
                }
            } catch {
                addSpend(model.cost(roundUsage), keyID: keyID)
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                let message = error.localizedDescription
                update(cid, mid) { m in
                    if !cancelled {
                        m.error = message
                    } else if m.text.isEmpty && m.toolSteps.isEmpty {
                        m.error = "Stopped."
                    }
                }
            }
            if tools != nil { saveTurns(turns, cid, mid) }
            streaming.remove(cid)
            streamTasks[cid] = nil
            save()
        }
    }

    func stop(_ cid: UUID? = nil) {
        guard let cid = cid ?? selectedID else { return }
        streamTasks[cid]?.cancel()
    }

    private func update(_ cid: UUID, _ mid: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = index(of: cid),
              let j = conversations[i].messages.firstIndex(where: { $0.id == mid }) else { return }
        change(&conversations[i].messages[j])
    }

    private func saveTurns(_ turns: [[String: Any]], _ cid: UUID, _ mid: UUID) {
        guard !turns.isEmpty, let data = try? JSONSerialization.data(withJSONObject: turns) else { return }
        let json = String(decoding: data, as: UTF8.self)
        update(cid, mid) { $0.apiTurns = json }
    }

    /// What a tool step says while it runs; replaced by the tool's own title when it finishes.
    static func stepTitle(_ name: String, _ input: [String: Any]) -> String {
        let path = (input["path"] as? String) ?? ""
        switch name {
        case "read_file": return "Reading \(path)"
        case "edit_file": return "Editing \(path)"
        case "write_file": return "Writing \(path)"
        case "delete_file": return "Deleting \(path)"
        case "search": return "Searching “\((input["pattern"] as? String) ?? "")”"
        case "list_files": return "Listing files"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Appends API turns to a message list, joining neighbours that share a role
    /// (the API needs user and assistant turns to alternate).
    static func merge(_ base: [[String: Any]], _ extra: [[String: Any]]) -> [[String: Any]] {
        var out = base
        for t in extra {
            if let last = out.last, (last["role"] as? String) == (t["role"] as? String),
               var content = last["content"] as? [[String: Any]], let more = t["content"] as? [[String: Any]] {
                content.append(contentsOf: more)
                out[out.count - 1]["content"] = content
            } else {
                out.append(t)
            }
        }
        return out
    }

    /// Turns the visible chat into alternating user/assistant API messages with content blocks.
    /// Attachments go before the text of their message, which is how Claude reads them best.
    static func apiMessages(_ msgs: [ChatMessage]) -> [[String: Any]] {
        var turns: [(role: Role, blocks: [[String: Any]])] = []
        for m in msgs {
            // A reply that used tools is sent back exactly as the API produced it, tool calls included.
            if m.role == .assistant, let json = m.apiTurns,
               let raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] {
                for t in raw {
                    guard let role = Role(rawValue: (t["role"] as? String) ?? ""),
                          let blocks = t["content"] as? [[String: Any]], !blocks.isEmpty else { continue }
                    if let last = turns.last, last.role == role {
                        turns[turns.count - 1].blocks.append(contentsOf: blocks)
                    } else {
                        turns.append((role: role, blocks: blocks))
                    }
                }
                continue
            }
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
