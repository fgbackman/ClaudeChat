import Foundation

// MARK: - Running git and gh

/// Runs command-line tools (git, gh) off the main thread. Apps launched from Finder get a bare PATH,
/// so Homebrew's folders are added to find `gh`.
enum Shell {
    struct Result {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
        var combined: String { [out, err].filter { !$0.isEmpty }.joined(separator: "\n") }
    }

    static func run(_ tool: String, _ args: [String], in dir: URL? = nil) async -> Result {
        await Task.detached { runSync(tool, args, in: dir) }.value
    }

    static func runSync(_ tool: String, _ args: [String], in dir: URL?) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["GIT_TERMINAL_PROMPT"] = "0"   // fail instead of waiting for a password nobody can type
        env["GH_PROMPT_DISABLED"] = "1"
        p.environment = env
        if let dir { p.currentDirectoryURL = dir }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return Result(status: -1, out: "", err: "Couldn't run \(tool): \(error.localizedDescription)")
        }
        // Read both pipes at once so a chatty command can't fill one and stall.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                      err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - GitHub repos

struct GitHubRepo: Identifiable, Decodable, Hashable {
    let nameWithOwner: String
    let description: String?
    let updatedAt: String?
    let isPrivate: Bool?

    var id: String { nameWithOwner }
    var name: String { nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner }
}

enum GitHub {
    /// Where repos are cloned: ~/Developer, next to your other projects.
    static var developerFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer", isDirectory: true)
    }

    static func listRepos() async throws -> [GitHubRepo] {
        let r = await Shell.run("gh", ["repo", "list", "--limit", "300",
                                       "--json", "nameWithOwner,description,updatedAt,isPrivate"])
        guard r.ok else {
            throw APIError(message: r.status == -1 || r.err.contains("No such file")
                ? "The GitHub command-line tool (gh) isn't installed. Install it with `brew install gh`, then run `gh auth login`."
                : "Couldn't list your GitHub repos: \(r.combined)")
        }
        return try JSONDecoder().decode([GitHubRepo].self, from: Data(r.out.utf8))
    }

    /// An existing clone of `repo` in ~/Developer, found by checking each folder's origin remote.
    static func existingClone(of repo: GitHubRepo) async -> URL? {
        let fm = FileManager.default
        let named = developerFolder.appendingPathComponent(repo.name)
        var candidates = [named]
        if let all = try? fm.contentsOfDirectory(at: developerFolder, includingPropertiesForKeys: nil) {
            candidates += all.filter { $0 != named }
        }
        for dir in candidates where fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            let r = await Shell.run("git", ["remote", "get-url", "origin"], in: dir)
            let url = r.out.lowercased()
            let want = repo.nameWithOwner.lowercased()
            if r.ok && (url.hasSuffix("/" + want) || url.hasSuffix("/" + want + ".git") || url.hasSuffix(":" + want + ".git")) {
                return dir
            }
        }
        return nil
    }

    /// Returns the local folder for `repo`, cloning it into ~/Developer first if needed.
    static func localFolder(for repo: GitHubRepo) async throws -> URL {
        if let dir = await existingClone(of: repo) { return dir }
        let fm = FileManager.default
        try? fm.createDirectory(at: developerFolder, withIntermediateDirectories: true)
        var dest = developerFolder.appendingPathComponent(repo.name)
        if fm.fileExists(atPath: dest.path) {
            dest = developerFolder.appendingPathComponent("\(repo.name)-\(repo.nameWithOwner.split(separator: "/")[0])")
        }
        let r = await Shell.run("gh", ["repo", "clone", repo.nameWithOwner, dest.path])
        guard r.ok else { throw APIError(message: "Couldn't clone \(repo.nameWithOwner): \(r.combined)") }
        return dest
    }
}

// MARK: - Tools Claude uses to work on a project

/// File and git tools scoped to one project folder. Claude can read, search and edit files there;
/// it can't run other commands, and committing and pushing stay with you (the Commit & Push button).
struct ProjectTools {
    let root: URL

    struct Output {
        var text: String
        var isError = false
        var title: String
        var detail = ""
    }

    static let maxOutput = 60_000

    static let definitions: [[String: Any]] = [
        tool("list_files",
             "List the files in the project (tracked and untracked, respecting .gitignore). Optionally limit to a subfolder.",
             ["path": ["type": "string", "description": "Subfolder relative to the project root. Omit for the whole project."]],
             required: []),
        tool("read_file",
             "Read a text file. Lines come back numbered (\"  12\\t…\"); the numbers are not part of the file. For large files, read a range.",
             ["path": ["type": "string", "description": "Path relative to the project root."],
              "start_line": ["type": "integer", "description": "First line to read (1-based)."],
              "end_line": ["type": "integer", "description": "Last line to read (inclusive)."]],
             required: ["path"]),
        tool("search",
             "Search file contents with an extended regular expression (git grep). Returns matching lines with file and line number.",
             ["pattern": ["type": "string", "description": "Extended regular expression."],
              "path": ["type": "string", "description": "Subfolder or file to limit the search to."],
              "ignore_case": ["type": "boolean"]],
             required: ["pattern"]),
        tool("edit_file",
             "Replace exact text in a file. old_string must match the file exactly (no line numbers) and be unique unless replace_all is true. Prefer this over write_file for changes to existing files.",
             ["path": ["type": "string"],
              "old_string": ["type": "string"],
              "new_string": ["type": "string"],
              "replace_all": ["type": "boolean"]],
             required: ["path", "old_string", "new_string"]),
        tool("write_file",
             "Create a file, or replace a file's whole contents. Creates folders as needed.",
             ["path": ["type": "string"], "content": ["type": "string"]],
             required: ["path", "content"]),
        tool("delete_file",
             "Delete a file from the project.",
             ["path": ["type": "string"]],
             required: ["path"]),
        tool("git",
             "Read-only git info: \"status\" (changed files), \"diff\" (uncommitted changes, optionally for one path), or \"log\" (recent commits).",
             ["command": ["type": "string", "enum": ["status", "diff", "log"]],
              "path": ["type": "string", "description": "Limit diff or log to this path."]],
             required: ["command"]),
    ]

    private static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "input_schema": ["type": "object", "properties": props, "required": required]]
    }

    static func systemPrompt(name: String, root: URL) -> String {
        """
        You are working on the user's project "\(name)", a git repository at \(root.path). \
        Use the tools to explore, read and edit its files; paths are relative to the project root. \
        Read files before changing them, and make focused edits with edit_file. \
        You can't run builds or other commands, and you don't commit or push: when a change is done, \
        say briefly what you changed and suggest a one-line commit message. The user reviews and pushes \
        with the Commit & Push button.
        """
    }

    // MARK: Running a tool

    func run(_ name: String, _ input: [String: Any]) async -> Output {
        do {
            switch name {
            case "list_files": return try await listFiles(input)
            case "read_file": return try readFile(input)
            case "search": return try await search(input)
            case "edit_file": return try editFile(input)
            case "write_file": return try writeFile(input)
            case "delete_file": return try deleteFile(input)
            case "git": return try await git(input)
            default: return Output(text: "Unknown tool \(name).", isError: true, title: name)
            }
        } catch {
            let path = input["path"] as? String
            return Output(text: error.localizedDescription, isError: true,
                          title: path.map { "\(name) \($0)" } ?? name, detail: error.localizedDescription)
        }
    }

    /// Resolves a project-relative path, refusing anything outside the project or inside .git.
    private func resolve(_ raw: String?, forWriting: Bool = false) throws -> URL {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw APIError(message: "A path is required.")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : base.appendingPathComponent(raw))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == base.path || url.path.hasPrefix(base.path + "/") else {
            throw APIError(message: "\(raw) is outside the project.")
        }
        if forWriting && url.pathComponents.dropFirst(base.pathComponents.count).contains(".git") {
            throw APIError(message: "Files inside .git can't be changed.")
        }
        return url
    }

    private func relative(_ url: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.path
        return p.hasPrefix(base + "/") ? String(p.dropFirst(base.count + 1)) : p
    }

    private static func cap(_ s: String, _ limit: Int = maxOutput) -> String {
        s.count > limit ? String(s.prefix(limit)) + "\n… (output cut off at \(limit) characters)" : s
    }

    private func listFiles(_ input: [String: Any]) async throws -> Output {
        let sub = input["path"] as? String
        var args = ["ls-files", "--cached", "--others", "--exclude-standard"]
        if let sub, !sub.isEmpty { args += ["--", relative(try resolve(sub))] }
        let r = await Shell.run("git", args, in: root)
        guard r.ok else { throw APIError(message: r.combined) }
        let files = r.out.split(separator: "\n")
        let shown = files.prefix(2000).joined(separator: "\n")
        let more = files.count > 2000 ? "\n… and \(files.count - 2000) more" : ""
        return Output(text: files.isEmpty ? "(no files)" : shown + more,
                      title: "Listed files" + (sub.map { " in \($0)" } ?? ""),
                      detail: "\(files.count) files")
    }

    private func readFile(_ input: [String: Any]) throws -> Output {
        let url = try resolve(input["path"] as? String)
        let data = try Data(contentsOf: url)
        guard !data.prefix(8000).contains(0) else {
            throw APIError(message: "\(relative(url)) looks like a binary file.")
        }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let start = max((input["start_line"] as? Int) ?? 1, 1)
        let end = min((input["end_line"] as? Int) ?? (start + 1999), lines.count)
        guard start <= max(end, 1) else { throw APIError(message: "The file has only \(lines.count) lines.") }
        let body = (start...max(end, start)).filter { $0 <= lines.count }.map {
            String(format: "%5d\t", $0) + lines[$0 - 1]
        }.joined(separator: "\n")
        let note = end < lines.count ? "\n… (\(lines.count) lines in total; read more with start_line)" : ""
        return Output(text: Self.cap(body) + note, title: "Read \(relative(url))",
                      detail: "lines \(start)–\(end) of \(lines.count)")
    }

    private func search(_ input: [String: Any]) async throws -> Output {
        guard let pattern = input["pattern"] as? String, !pattern.isEmpty else {
            throw APIError(message: "A pattern is required.")
        }
        var args = ["grep", "-n", "-I", "-E", "--untracked"]
        if input["ignore_case"] as? Bool == true { args.append("-i") }
        args += ["-e", pattern]
        if let p = input["path"] as? String, !p.isEmpty { args += ["--", relative(try resolve(p))] }
        let r = await Shell.run("git", args, in: root)
        if r.status == 1 { return Output(text: "No matches.", title: "Searched “\(pattern)”", detail: "no matches") }
        guard r.ok else { throw APIError(message: r.combined) }
        let lines = r.out.split(separator: "\n")
        let shown = lines.prefix(300).map { String($0.prefix(400)) }.joined(separator: "\n")
        let more = lines.count > 300 ? "\n… and \(lines.count - 300) more matches" : ""
        return Output(text: Self.cap(shown + more), title: "Searched “\(pattern)”", detail: "\(lines.count) matches")
    }

    private func editFile(_ input: [String: Any]) throws -> Output {
        let url = try resolve(input["path"] as? String, forWriting: true)
        guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else {
            throw APIError(message: "old_string and new_string are required.")
        }
        guard !old.isEmpty else { throw APIError(message: "old_string is empty. Use write_file to create a file.") }
        let text = try String(contentsOf: url, encoding: .utf8)
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else {
            throw APIError(message: "old_string wasn't found in \(relative(url)). Read the file again and copy the text exactly, without line numbers.")
        }
        let all = input["replace_all"] as? Bool == true
        guard count == 1 || all else {
            throw APIError(message: "old_string appears \(count) times in \(relative(url)). Include more surrounding text, or set replace_all.")
        }
        let updated: String
        if all {
            updated = text.replacingOccurrences(of: old, with: new)
        } else {
            let r = text.range(of: old)!
            updated = text.replacingCharacters(in: r, with: new)
        }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        let added = new.components(separatedBy: "\n").count, removed = old.components(separatedBy: "\n").count
        return Output(text: "Edited \(relative(url)) (\(all ? count : 1) replacement\(all && count > 1 ? "s" : "")).",
                      title: "Edited \(relative(url))", detail: "+\(added) −\(removed) lines")
    }

    private func writeFile(_ input: [String: Any]) throws -> Output {
        let url = try resolve(input["path"] as? String, forWriting: true)
        guard let content = input["content"] as? String else { throw APIError(message: "content is required.") }
        let existed = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").count
        return Output(text: "\(existed ? "Replaced" : "Created") \(relative(url)) (\(lines) lines).",
                      title: "\(existed ? "Rewrote" : "Created") \(relative(url))", detail: "\(lines) lines")
    }

    private func deleteFile(_ input: [String: Any]) throws -> Output {
        let url = try resolve(input["path"] as? String, forWriting: true)
        guard url.path != root.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw APIError(message: "Can't delete the project folder.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw APIError(message: "\(relative(url)) isn't a file.")
        }
        try FileManager.default.removeItem(at: url)
        return Output(text: "Deleted \(relative(url)).", title: "Deleted \(relative(url))")
    }

    private func git(_ input: [String: Any]) async throws -> Output {
        let command = (input["command"] as? String) ?? "status"
        var pathArgs: [String] = []
        if let p = input["path"] as? String, !p.isEmpty { pathArgs = ["--", relative(try resolve(p))] }
        let args: [String]
        switch command {
        case "status": args = ["status", "--short", "--branch"]
        case "diff": args = ["diff", "HEAD"] + pathArgs
        case "log": args = ["log", "--oneline", "-20"] + pathArgs
        default: throw APIError(message: "Unknown git command \(command). Use status, diff or log.")
        }
        let r = await Shell.run("git", args, in: root)
        guard r.ok else { throw APIError(message: r.combined) }
        return Output(text: r.out.isEmpty ? "(nothing)" : Self.cap(r.out), title: "git \(command)")
    }
}
