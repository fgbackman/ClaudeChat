import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Shows the app in the Dock with its icon, even when launched as a bare binary (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running in the menu bar after the last chat window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no windows open brings a chat window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct ClaudeChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ChatStore()
    @State private var rebuilder = Rebuilder()

    var body: some Scene {
        WindowGroup("Claude", id: "main") {
            ContentView()
                .environment(store)
                .environment(rebuilder)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            ChatCommands(store: store)
            AppearanceCommands()
            RebuildCommands(rebuilder: rebuilder)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(rebuilder)
        }
    }
}

/// File and Edit menu commands. They act on the chat in the focused tab.
struct ChatCommands: Commands {
    let store: ChatStore
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.chatSelection) private var selection: UUID??

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { openWindow(id: "main") }
                .keyboardShortcut("t")
            Button("New Chat") {
                if selection != nil {
                    selection = store.newConversation(replacing: selection ?? nil)
                } else {
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut("n")
            Divider()
            Button("Attach Files…") {
                if let id = selection ?? nil { store.chooseAttachments(for: id) }
            }
            .keyboardShortcut("o")
            .disabled((selection ?? nil) == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Paste as Attachment") {
                if let id = selection ?? nil { store.attachFromClipboard(to: id) }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled((selection ?? nil) == nil)
        }
    }
}
