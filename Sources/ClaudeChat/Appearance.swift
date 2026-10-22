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

/// Text colour used by the terminal style.
enum TerminalColor: String, CaseIterable, Identifiable {
    case white, green, amber

    var id: String { rawValue }
    var label: String {
        switch self {
        case .white: "White"
        case .green: "Green"
        case .amber: "Amber"
        }
    }
    var color: Color {
        switch self {
        case .white: Color(white: 0.92)
        case .green: Color(red: 0.25, green: 0.95, blue: 0.35)
        case .amber: Color(red: 1.0, green: 0.69, blue: 0.0)
        }
    }
}

/// How "see-through" is done.
enum SeeThroughMode: String, CaseIterable, Identifiable {
    case fade, blur

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fade: "Fade window"
        case .blur: "Blur background"
        }
    }
}

enum AppearanceKey {
    static let style = "chatStyle"
    static let color = "terminalColor"
    static let mode = "seeThroughMode"
    static let opacity = "windowOpacity"
    static let minOpacity = 0.3
}

/// A blurred view of whatever is behind the window.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = material
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

extension View {
    /// Terminal look: monospaced, coloured text, black background, hidden list backgrounds.
    /// With `blur` on, the window supplies the background, so none is drawn here.
    /// No-op for the standard style.
    @ViewBuilder
    func chatStyle(_ style: ChatStyle, color: TerminalColor, blur: Bool) -> some View {
        if style == .terminal {
            self
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(color.color)
                .tint(color.color)
                .scrollContentBackground(.hidden)
                .background(blur ? Color.clear : Color.black)
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
