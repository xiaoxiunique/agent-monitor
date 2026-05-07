import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class EnvironmentController {
    enum CommandState: Equatable {
        case installed(String)
        case managed(String)
        case missing
        case conflict(String)

        var title: String {
            switch self {
            case .installed: "Installed"
            case .managed: "Managed"
            case .missing: "Missing"
            case .conflict: "Conflict"
            }
        }

        var isInstalled: Bool {
            switch self {
            case .installed, .managed: true
            case .missing, .conflict: false
            }
        }
    }

    var tmuxPath: String?
    var tmuxVersion: String?
    var brewPath: String?
    var ccState: CommandState = .missing
    var cxState: CommandState = .missing
    var isWorking = false
    var lastMessage = ""

    private let fileManager = FileManager.default
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var wrapperDirectory: URL {
        homeDirectory.appendingPathComponent(".agent-monitor/bin", isDirectory: true)
    }

    init() {
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        tmuxPath = await Self.firstLine("/bin/zsh", "-lc", "command -v tmux || true")
        if tmuxPath?.isEmpty == true { tmuxPath = nil }

        if tmuxPath != nil {
            tmuxVersion = await Self.firstLine("/bin/zsh", "-lc", "tmux -V || true")
        } else {
            tmuxVersion = nil
        }

        brewPath = await Self.firstLine("/bin/zsh", "-lc", "command -v brew || true")
        if brewPath?.isEmpty == true { brewPath = nil }

        ccState = await commandState(name: "cc")
        cxState = await commandState(name: "cx")
    }

    func installWrappers() async {
        isWorking = true
        defer { isWorking = false }

        do {
            try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
            try writeWrapper(name: "cc", commandVariable: "AGENT_MONITOR_CC_COMMAND", defaultCommand: "claude")
            try writeWrapper(name: "cx", commandVariable: "AGENT_MONITOR_CX_COMMAND", defaultCommand: "codex --yolo")
            try ensureZshrcPathBlock()
            lastMessage = "Installed cc/cx wrappers. Run `source ~/.zshrc` in existing shells."
            await refresh()
        } catch {
            lastMessage = "Failed to install wrappers: \(error.localizedDescription)"
        }
    }

    func openTmuxInstallTerminal() {
        guard let brewPath else {
            lastMessage = "Homebrew is missing. Install Homebrew first, then run `brew install tmux`."
            NSWorkspace.shared.open(URL(string: "https://brew.sh/")!)
            return
        }

        let command = "\(brewPath) install tmux; echo; echo 'tmux install finished. You can close this window.'"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }

        if let error {
            lastMessage = "Failed to open Terminal: \(error)"
        } else {
            lastMessage = "Opened Terminal to install tmux."
        }
    }

    func copyDiagnostics(service: ServiceController) {
        let diagnostics = """
        Agent Monitor Diagnostics
        Service: \(service.state.title)
        Local URL: \(service.dashboardURL.absoluteString)
        Phone URL: \(service.phoneDashboardURL.absoluteString)
        Tailscale: \(service.tailscaleHost ?? "none")
        LAN: \(service.lanHost ?? "none")
        tmux: \(tmuxVersion ?? "missing")
        tmux path: \(tmuxPath ?? "missing")
        cc: \(describe(ccState))
        cx: \(describe(cxState))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        lastMessage = "Copied diagnostics."
    }

    private func commandState(name: String) async -> CommandState {
        let wrapperPath = wrapperDirectory.appendingPathComponent(name).path
        if fileManager.isExecutableFile(atPath: wrapperPath),
           let content = try? String(contentsOfFile: wrapperPath),
           content.contains("AGENT_MONITOR_WRAPPER") {
            return .installed(wrapperPath)
        }

        if let managedDetail = compatibleShellFunctionDetail(name: name) {
            return .managed(managedDetail)
        }

        let output = await Self.output("/bin/zsh", "-lic", "type -a \(name) 2>/dev/null || true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return .missing
        }

        return .conflict(output.components(separatedBy: .newlines).prefix(2).joined(separator: "\n"))
    }

    private func writeWrapper(name: String, commandVariable: String, defaultCommand: String) throws {
        let url = wrapperDirectory.appendingPathComponent(name)
        let content = """
        #!/usr/bin/env bash
        set -euo pipefail
        # AGENT_MONITOR_WRAPPER \(name)

        if ! command -v tmux >/dev/null 2>&1; then
          echo "Agent Monitor requires tmux. Install it first: brew install tmux" >&2
          exit 1
        fi

        project_dir="$(pwd -P)"
        base="$(basename "$project_dir" | tr -c '[:alnum:]_-' '_' | sed 's/_$//')"
        hash="$(printf "%s" "$project_dir" | shasum -a 1 | awk '{print substr($1, 1, 8)}')"
        session="\(name)_${base}_${hash}"
        agent_command="${\(commandVariable):-\(defaultCommand)}"

        if tmux has-session -t "$session" 2>/dev/null; then
          if [ -n "${TMUX:-}" ]; then
            exec tmux switch-client -t "$session"
          fi
          exec tmux attach-session -t "$session"
        fi

        if [ -n "${TMUX:-}" ]; then
          tmux new-session -d -s "$session" -c "$project_dir" "$agent_command"
          exec tmux switch-client -t "$session"
        fi

        exec tmux new-session -s "$session" -c "$project_dir" "$agent_command"
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func ensureZshrcPathBlock() throws {
        let zshrc = homeDirectory.appendingPathComponent(".zshrc")
        let block = """

        # >>> agent-monitor >>>
        export PATH="$HOME/.agent-monitor/bin:$PATH"
        # <<< agent-monitor <<<
        """

        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !existing.contains("# >>> agent-monitor >>>") else { return }

        let updated = existing.isEmpty ? block.trimmingCharacters(in: .newlines) + "\n" : existing + block + "\n"
        try updated.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    private func compatibleShellFunctionDetail(name: String) -> String? {
        let zshrc = homeDirectory.appendingPathComponent(".zshrc")
        guard let content = try? String(contentsOf: zshrc, encoding: .utf8) else {
            return nil
        }

        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?ms)^\s*(?:function\s+)?"# + escapedName + #"(?:\s*\(\s*\)|\s+)\s*\{(?<body>.*?)^\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let bodyRange = Range(match.range(withName: "body"), in: content) else {
            return nil
        }

        let body = String(content[bodyRange])
        guard body.contains("_agent_tmux_run") else {
            return nil
        }

        let expectedCommand = name == "cc" ? "claude" : "codex"
        guard body.contains(expectedCommand) else {
            return nil
        }

        return "\(name) is managed by ~/.zshrc using _agent_tmux_run"
    }

    private func describe(_ state: CommandState) -> String {
        switch state {
        case .installed(let path): "installed at \(path)"
        case .managed(let detail): detail
        case .missing: "missing"
        case .conflict(let detail): "conflict: \(detail)"
        }
    }

    private static func firstLine(_ executable: String, _ arguments: String...) async -> String? {
        let text = await output(executable, arguments)
        return text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func output(_ executable: String, _ arguments: String...) async -> String {
        await output(executable, arguments)
    }

    private static func output(_ executable: String, _ arguments: [String]) async -> String {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            } catch {
                return ""
            }
        }.value
    }
}
