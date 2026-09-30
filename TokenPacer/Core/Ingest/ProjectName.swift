import Foundation
import os

/// The project a working directory belongs to: the repository it sits in.
///
/// A log's `cwd` is where the agent happened to be, not what it was working
/// on. Claude writes it per line and it follows every `cd`, so one session in
/// one repository came out as `src`, `locales`, `modules`, `rate-limit` — a
/// dozen rows in By project for what was one project. Subagents and Copilot
/// work in worktrees whose folder is a generated name.
///
/// So the directory is walked up to the first `.git`. A worktree's `.git` is a
/// file naming the main repository, which is the project. A directory in no
/// repository keeps its own name, and one inside an agent's own home — Copilot
/// opens its chats in `~/.copilot/chats/<id>` — is no project at all.
enum ProjectName {
    /// Resolved once per directory: a few `stat`s the first time, a dictionary
    /// lookup every event after.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String?]())

    static func of(_ cwd: String) -> String? {
        if let hit = cache.withLock({ $0[cwd] }) { return hit }
        let name = resolve(cwd)
        cache.withLock { $0[cwd] = name }
        return name
    }

    static func resolve(_ cwd: String, fileManager: FileManager = .default) -> String? {
        let start = URL(filePath: cwd).standardized
        let homes = [AgentHome.claude, AgentHome.codex, AgentHome.copilot].map(\.standardized.path)
        if homes.contains(where: { start.path == $0 || start.path.hasPrefix($0 + "/") }) { return nil }

        // Never the home folder itself: a dotfiles repository there would claim
        // every directory under it.
        let home = fileManager.homeDirectoryForCurrentUser.standardized.path
        var directory = start
        while directory.path != "/", directory.path != home {
            let git = directory.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue, let main = worktreeOwner(git) { return main }
                return directory.lastPathComponent
            }
            directory = directory.deletingLastPathComponent()
        }
        return start.lastPathComponent
    }

    /// `gitdir: /…/duotyping/.git/worktrees/agent-a06c…` → `duotyping`. A
    /// submodule's `.git` file points into `.git/modules` instead, and is its
    /// own project.
    private static func worktreeOwner(_ git: URL) -> String? {
        guard let text = try? String(contentsOf: git, encoding: .utf8),
              let marker = text.range(of: "/.git/worktrees/")
        else { return nil }
        let main = text[..<marker.lowerBound].replacing("gitdir:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(filePath: main).lastPathComponent
    }
}
