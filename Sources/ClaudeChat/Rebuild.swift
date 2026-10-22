import Foundation
import AppKit
import Observation

/// Rebuilds and reinstalls this app from its source folder by running `build-app.sh`.
/// That script quits the running copy, installs the new build to ~/Applications and relaunches it,
/// so on success this app simply restarts. On failure it stays open and shows the end of the log.
@MainActor
@Observable
final class Rebuilder {
    enum State: Equatable {
        case idle
        case building
        case failed(String)
    }

    var state: State = .idle
    var sourcePath: String {
        didSet { UserDefaults.standard.set(sourcePath, forKey: "sourcePath") }
    }

    init() {
        sourcePath = UserDefaults.standard.string(forKey: "sourcePath")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Developer/ClaudeChat")
    }

    var scriptPath: String { (sourcePath as NSString).appendingPathComponent("build-app.sh") }
    var hasSource: Bool { FileManager.default.fileExists(atPath: scriptPath) }
    var isBuilding: Bool { state == .building }

    /// Where the build output goes, so it survives this app being replaced.
    private var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rebuild.log")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the ClaudeChat source folder (the one containing build-app.sh)"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { sourcePath = url.path }
    }

    func rebuild() {
        guard !isBuilding else { return }
        guard hasSource else {
            state = .failed("Couldn't find build-app.sh in \(sourcePath). Choose the source folder in Settings.")
            return
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            state = .failed("Couldn't write the build log.")
            return
        }
        state = .building

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell so `swift` is found the same way it is in Terminal.
        p.arguments = ["-lc", "cd \"$CLAUDECHAT_SRC\" && bash ./build-app.sh"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDECHAT_SRC"] = sourcePath
        p.environment = env
        // Output goes to a file, not a pipe: the script quits this app near the end,
        // and a pipe closing under it would kill the script before it relaunches.
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            try? log.close()
            Task { @MainActor in self?.finished(status: status) }
        }
        do {
            try p.run()
        } catch {
            state = .failed("Couldn't start the build: \(error.localizedDescription)")
        }
    }

    private func finished(status: Int32) {
        if status == 0 {
            state = .idle   // normally we've already been replaced and relaunched by now
        } else {
            state = .failed("Build failed (exit \(status)). Last lines of the log:\n\n\(logTail())")
        }
    }

    private func logTail(lines: Int = 25) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "(no log)" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }
}

/// Banner shown over the window while rebuilding, or when a rebuild failed.
@MainActor
struct RebuildBanner: View {
    @Environment(Rebuilder.self) private var rebuilder

    var body: some View {
        switch rebuilder.state {
        case .idle:
            EmptyView()
        case .building:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Rebuilding… Claude Chat will restart when it's done (can take a minute or two).")
                    .font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .padding(.top, 10)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Rebuild failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                ScrollView {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                HStack {
                    Button("Show Log") { rebuilder.revealLog() }
                    Button("Copy") { Pasteboard.copy(message) }
                    Spacer()
                    Button("Dismiss") { rebuilder.state = .idle }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 6)
            .padding(.top, 10)
        }
    }
}

/// App menu item: Claude Chat → Rebuild & Reinstall
struct RebuildCommands: Commands {
    let rebuilder: Rebuilder

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Rebuild & Reinstall") { rebuilder.rebuild() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(rebuilder.isBuilding)
        }
    }
}
