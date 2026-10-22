import SwiftUI
import AppKit

/// How the chat looks. Stored with @AppStorage so every window and tab updates together.
enum ChatStyle: String, CaseIterable, Identifiable {
    case standard, terminal

    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "Standard"
        case .terminal: "Terminal"
        }
    }
}

enum AppearanceKey {
    static let style = "chatStyle"
    static let opacity = "windowOpacity"
    static let minOpacity = 0.3
}

extension View {
    /// Terminal look: dark, monospaced, black background. No-op for the standard style.
    @ViewBuilder
    func chatStyle(_ style: ChatStyle) -> some View {
        if style == .terminal {
            self
                .font(.system(.body, design: .monospaced))
                .background(Color.black)
                .preferredColorScheme(.dark)
        } else {
            self
        }
    }
}

/// Menu commands to switch style and make the window more or less see-through.
struct AppearanceCommands: Commands {
    @AppStorage(AppearanceKey.style) private var styleRaw = ChatStyle.standard.rawValue
    @AppStorage(AppearanceKey.opacity) private var opacity = 1.0

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(styleRaw == ChatStyle.terminal.rawValue ? "Standard Style" : "Terminal Style") {
                styleRaw = styleRaw == ChatStyle.terminal.rawValue
                    ? ChatStyle.standard.rawValue : ChatStyle.terminal.rawValue
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            Button("More See-Through") {
                opacity = max(AppearanceKey.minOpacity, opacity - 0.1)
            }
            .keyboardShortcut("-", modifiers: [.command, .option])
            Button("Less See-Through") {
                opacity = min(1.0, opacity + 0.1)
            }
            .keyboardShortcut("=", modifiers: [.command, .option])
            Divider()
        }
    }
}
