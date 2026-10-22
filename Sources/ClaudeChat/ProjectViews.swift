import SwiftUI
import AppKit

// MARK: - Toolbar menu

@MainActor
struct ProjectMenu: View {
    let conversation: Conversation?
    let pick: () -> Void
    let commit: () -> Void
    let detach: () -> Void

    var body: some View {
        Menu {
            Button(conversation?.projectURL == nil ? "Open GitHub Project…" : "Switch Project…", action: pick)
            if let root = conversation?.projectURL {
                Button("Commit & Push…", action: commit)
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                Button("Open on GitHub") {
                    Task { _ = await Shell.run("gh", ["browse"], in: root) }
                }
                Divider()
                Button("Close Project", action: detach)
            }
        } label: {
            Label(conversation?.projectName.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "Project",
                  systemImage: conversation?.projectURL == nil ? "folder.badge.plus" : "folder")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Let Claude edit one of your GitHub projects in this chat")
    }
}

// MARK: - Picking a repo

@MainActor
struct ProjectPicker: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID

    @State private var repos: [GitHubRepo] = []
    @State private var query = ""
    @State private var loading = true
    @State private var opening: String?
    @State private var error: String?

    private var filtered: [GitHubRepo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return repos }
        return repos.filter { $0.nameWithOwner.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a GitHub Project")
                .font(.title3.weight(.semibold))
            Text("Claude can read and edit the project's files in this chat. Repos not on this Mac yet are cloned into ~/Developer.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Search your repos", text: $query)
                .textFieldStyle(.roundedBorder)

            Group {
                if loading {
                    ProgressView("Loading your repos…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { repo in
                        Button {
                            open(repo)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(repo.name).font(.body.weight(.medium))
                                        if repo.isPrivate == true {
                                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    if let d = repo.description, !d.isEmpty {
                                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if opening == repo.id { ProgressView().controlSize(.small) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(opening != nil)
                    }
                }
            }
            .frame(minHeight: 300)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Open Local Folder…", action: openLocal)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 540)
        .task {
            do {
                repos = try await GitHub.listRepos()
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func open(_ repo: GitHubRepo) {
        opening = repo.id
        error = nil
        Task {
            do {
                let folder = try await GitHub.localFolder(for: repo)
                store.setProject(folder, name: repo.nameWithOwner, for: conversationID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            opening = nil
        }
    }

    private func openLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = GitHub.developerFolder
        panel.prompt = "Open"
        panel.message = "Choose a project folder (a git repository) for Claude to work on"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            error = "\(url.lastPathComponent) isn't a git repository, so its changes couldn't be reviewed or undone. Pick a repo folder."
            return
        }
        Task {
            let r = await Shell.run("git", ["remote", "get-url", "origin"], in: url)
            let name = r.ok ? Self.repoName(fromRemote: r.out) ?? url.lastPathComponent : url.lastPathComponent
            store.setProject(url, name: name, for: conversationID)
            dismiss()
        }
    }

    /// "https://github.com/owner/repo.git" or "git@github.com:owner/repo.git" → "owner/repo"
    static func repoName(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }
}

// MARK: - Commit & push

@MainActor
struct CommitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let name: String

    @State private var branch = ""
    @State private var status = ""
    @State private var diffStat = ""
    @State private var message = ""
    @State private var working = false
    @State private var output = ""
    @State private var failed = false
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit & Push \(name)")
                .font(.title3.weight(.semibold))
            Text(branch.isEmpty ? " " : "Branch: \(branch)")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(status.isEmpty ? "No changes." : status + (diffStat.isEmpty ? "" : "\n\n" + diffStat))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 160)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            TextField("Commit message", text: $message, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(status.isEmpty || done)

            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(failed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }

            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(done ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !done {
                    Button("Commit & Push", action: commitAndPush)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || status.isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task { await refresh() }
    }

    private func refresh() async {
        branch = await Shell.run("git", ["rev-parse", "--abbrev-ref", "HEAD"], in: root).out
        status = await Shell.run("git", ["status", "--short"], in: root).out
        diffStat = await Shell.run("git", ["diff", "--stat", "HEAD"], in: root).out
    }

    private func commitAndPush() {
        working = true
        failed = false
        output = ""
        Task {
            defer { working = false }
            let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
            for step in [["add", "-A"], ["commit", "-m", msg]] {
                let r = await Shell.run("git", step, in: root)
                if !r.ok {
                    failed = true
                    output = r.combined
                    return
                }
            }
            var push = await Shell.run("git", ["push"], in: root)
            if !push.ok && push.err.contains("no upstream") {
                push = await Shell.run("git", ["push", "-u", "origin", "HEAD"], in: root)
            }
            await refresh()
            if push.ok {
                output = "Committed and pushed to GitHub."
                done = true
            } else {
                failed = true
                output = "Committed on this Mac, but the push failed:\n" + push.combined
            }
        }
    }
}

// MARK: - Tool activity in a reply

@MainActor
struct ToolStepsView: View {
    let steps: [ToolStep]
    let isLive: Bool
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if !step.done {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: step.isError ? "exclamationmark.triangle" : Self.icon(step.title))
                                    .foregroundStyle(step.isError ? Color.red : Color.secondary)
                            }
                        }
                        .frame(width: 14)
                        Text(step.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .foregroundStyle(step.isError ? Color.red : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(isLive ? "Working on the project… (\(steps.count) steps)" : "Project activity (\(steps.count) steps)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func icon(_ title: String) -> String {
        if title.hasPrefix("Edited") || title.hasPrefix("Rewrote") { return "pencil" }
        if title.hasPrefix("Created") { return "doc.badge.plus" }
        if title.hasPrefix("Deleted") { return "trash" }
        if title.hasPrefix("Searched") { return "magnifyingglass" }
        if title.hasPrefix("git") { return "arrow.triangle.branch" }
        if title.hasPrefix("Listed") { return "list.bullet" }
        return "doc.text"
    }
}
