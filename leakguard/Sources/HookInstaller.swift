import Foundation

/// Installs a git pre-commit hook that blocks commits adding API keys or private keys.
/// Never overwrites a hook it didn't write.
enum HookInstaller {
    static let marker = "# Installed by LeakGuard"

    enum Status: Equatable {
        case notRepo
        case notInstalled
        case installed
        case otherHookPresent
    }

    enum HookError: LocalizedError {
        case notRepo, otherHook, notOurs
        var errorDescription: String? {
            switch self {
            case .notRepo:   return "This folder isn't a git repository."
            case .otherHook: return "This repo already has a pre-commit hook. LeakGuard won't overwrite it — add the check to it manually."
            case .notOurs:   return "The pre-commit hook here wasn't installed by LeakGuard, so it was left alone."
            }
        }
    }

    /// ERE patterns (BSD and GNU grep compatible) — a subset of SecretRules focused on
    /// high-confidence key formats, so the hook rarely blocks by mistake.
    static let pattern = [
        #"sk-ant-[A-Za-z0-9_-]{32,}"#,
        #"sk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{32,}"#,
        #"(AKIA|ASIA)[0-9A-Z]{16}"#,
        #"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}"#,
        #"github_pat_[A-Za-z0-9_]{60,}"#,
        #"glpat-[A-Za-z0-9_-]{20,}"#,
        #"xox[abposr]-[A-Za-z0-9-]{10,}"#,
        #"hooks\.slack\.com/services/[A-Za-z0-9/]{20,}"#,
        #"(sk|rk)_live_[A-Za-z0-9]{20,}"#,
        #"AIza[0-9A-Za-z_-]{35}"#,
        #"hf_[A-Za-z0-9]{30,}"#,
        #"gsk_[A-Za-z0-9]{40,}"#,
        #"r8_[A-Za-z0-9]{30,}"#,
        #"npm_[A-Za-z0-9]{36}"#,
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY"#,
    ].joined(separator: "|")

    static var script: String {
        """
        #!/bin/bash
        \(marker) — blocks commits that add API keys or private keys.
        # Remove it from LeakGuard, or delete this file. Bypass once: git commit --no-verify
        PATTERN='\(pattern)'
        found=0
        while IFS= read -r -d '' file; do
          if git diff --cached -U0 --no-color --no-ext-diff --no-textconv -- "$file" \\
               | grep -E '^\\+' | grep -vE '^\\+\\+\\+ ' | grep -qE -- "$PATTERN"; then
            if [ $found -eq 0 ]; then
              echo "✗ LeakGuard blocked this commit. It adds what looks like a secret in:" >&2
            fi
            echo "    $file" >&2
            found=1
          fi
        done < <(git diff --cached --name-only -z --diff-filter=ACMR)
        if [ $found -ne 0 ]; then
          echo "" >&2
          echo "  Move the secret to an environment variable or a git-ignored file, then commit again." >&2
          echo "  False positive? Commit with: git commit --no-verify" >&2
          exit 1
        fi
        exit 0

        """
    }

    /// Respects core.hooksPath (e.g. Husky) and linked worktrees.
    static func hooksDirectory(repo: URL) -> URL? {
        if let data = try? GitRunner.run(["config", "--get", "core.hooksPath"], in: repo, timeout: 10) {
            var path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                if path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst(1) }
                return path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appendingPathComponent(path)
            }
        }
        guard let data = try? GitRunner.run(["rev-parse", "--path-format=absolute", "--git-common-dir"],
                                            in: repo, timeout: 10) else { return nil }
        let dir = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : URL(fileURLWithPath: dir).appendingPathComponent("hooks")
    }

    static func status(repo: URL?) -> Status {
        guard let repo, let dir = hooksDirectory(repo: repo) else { return .notRepo }
        let hook = dir.appendingPathComponent("pre-commit")
        guard let existing = try? String(contentsOf: hook, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: hook.path) ? .otherHookPresent : .notInstalled
        }
        return existing.contains(marker) ? .installed : .otherHookPresent
    }

    static func install(repo: URL) throws {
        guard let dir = hooksDirectory(repo: repo) else { throw HookError.notRepo }
        let hook = dir.appendingPathComponent("pre-commit")
        let fm = FileManager.default
        if fm.fileExists(atPath: hook.path) {
            let existing = (try? String(contentsOf: hook, encoding: .utf8)) ?? ""
            guard existing.contains(marker) else { throw HookError.otherHook }
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: hook, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    static func uninstall(repo: URL) throws {
        guard let dir = hooksDirectory(repo: repo) else { throw HookError.notRepo }
        let hook = dir.appendingPathComponent("pre-commit")
        let existing = (try? String(contentsOf: hook, encoding: .utf8)) ?? ""
        guard existing.contains(marker) else { throw HookError.notOurs }
        try FileManager.default.removeItem(at: hook)
    }
}
