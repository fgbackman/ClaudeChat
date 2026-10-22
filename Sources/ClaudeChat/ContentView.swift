import SwiftUI
import AppKit

/// One window or tab. Each tab shows its own chat, so several sessions can run side by side.
@MainActor
struct ContentView: View {
    @Environment(ChatStore.self) private var store
    @State private var selectedID: UUID?
    @State private var window: NSWindow?
    @AppStorage(AppearanceKey.style) private var styleRaw = ChatStyle.standard.rawValue
    @AppStorage(AppearanceKey.opacity) private var opacity = 1.0
    @AppStorage(AppearanceKey.color) private var colorRaw = TerminalColor.green.rawValue
    @AppStorage(AppearanceKey.mode) private var modeRaw = SeeThroughMode.fade.rawValue

    private var style: ChatStyle { ChatStyle(rawValue: styleRaw) ?? .standard }
    private var termColor: TerminalColor { TerminalColor(rawValue: colorRaw) ?? .green }
    private var blur: Bool { modeRaw == SeeThroughMode.blur.rawValue }

    var body: some View {
        NavigationSplitView {
            Sidebar(selectedID: $selectedID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                .chatStyle(style, color: termColor, blur: blur)
        } detail: {
            Group {
                if store.apiKey.isEmpty {
                    WelcomeView()
                } else if let id = selectedID, store.conversation(id) != nil {
                    ChatView(conversationID: id, selectedID: $selectedID)
                        .id(id)
                } else {
                    Text("No chat selected")
                        .foregroundStyle(.secondary)
                }
            }
            .chatStyle(style, color: termColor, blur: blur)
        }
        .preferredColorScheme(style == .terminal ? .dark : nil)
        .background {
            // Blur mode: a real blur of what's behind the window, tinted by the see-through slider.
            if blur {
                ZStack {
                    VisualEffectBackground(material: style == .terminal ? .hudWindow : .underWindowBackground)
                    (style == .terminal ? Color.black : Color(nsColor: .windowBackgroundColor))
                        .opacity(opacity)
                }
                .ignoresSafeArea()
            }
        }
        .background(WindowAccessor(window: $window))
        .onChange(of: window) { applyWindowLook() }
        .onChange(of: opacity) { applyWindowLook() }
        .onChange(of: modeRaw) { applyWindowLook() }
        .focusedSceneValue(\.chatSelection, $selectedID)
        .onAppear {
            guard selectedID == nil else { return }
            // The first window picks up where you left off; each new tab starts a fresh chat.
            if !store.openedFirstWindow, let id = store.selectedID ?? store.sortedConversations.first?.id {
                selectedID = id
            } else {
                selectedID = store.newConversation()
            }
            store.openedFirstWindow = true
        }
        .onChange(of: selectedID) {
            if let id = selectedID { store.selectedID = id }
        }
        .onChange(of: store.conversations.map(\.id)) {
            if store.conversation(selectedID) == nil { selectedID = store.sortedConversations.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // The focused tab's chat is the one the menu bar panel shows.
            if let w = note.object as? NSWindow, w === window, let id = selectedID { store.selectedID = id }
        }
    }
}

extension ContentView {
    /// Fade mode lowers the whole window's alpha. Blur mode makes the window itself
    /// transparent and lets the blurred background view (see `body`) do the work.
    fileprivate func applyWindowLook() {
        guard let w = window else { return }
        if blur {
            w.alphaValue = 1
            w.isOpaque = false
            w.backgroundColor = .clear
        } else {
            w.alphaValue = min(1, max(AppearanceKey.minOpacity, opacity))
            w.isOpaque = true
            w.backgroundColor = .windowBackgroundColor
        }
    }
}

/// Finds the NSWindow hosting a view, and makes new chat windows open as tabs of the current one.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.tabbingMode = .preferred
            w.tabbingIdentifier = "ClaudeChatMain"
            window = w
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ChatSelectionKey: FocusedValueKey {
    typealias Value = Binding<UUID?>
}

extension FocusedValues {
    /// The chat shown in the focused tab, so menu commands (⌘N, ⌘O…) act on that tab.
    var chatSelection: Binding<UUID?>? {
        get { self[ChatSelectionKey.self] }
        set { self[ChatSelectionKey.self] = newValue }
    }
}

// MARK: - Sidebar

@MainActor
struct Sidebar: View {
    @Environment(ChatStore.self) private var store
    @Binding var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.sortedConversations) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(c.title)
                                .lineLimit(1)
                            if store.isStreaming(c.id) {
                                Spacer()
                                ProgressView().controlSize(.mini)
                            }
                        }
                        if let p = c.projectName {
                            Label(p.split(separator: "/").last.map(String.init) ?? p, systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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
                    selectedID = store.newConversation(replacing: selectedID)
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
