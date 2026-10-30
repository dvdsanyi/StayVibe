import AppKit
import Darwin
import StayVibeCore

/// Reads the installed Codex client's account snapshot without starting a thread or a turn.
enum CodexUsageClient {
    @MainActor static func fetch() async -> AgentUsage? {
        guard let executable = executableURL() else { return nil }
        return await Task.detached(priority: .utility) { read(from: executable) }.value
    }

    @MainActor private static func executableURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates += ["Contents/Resources/codex-cli/bin/codex",
                           "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                           "Contents/Resources/codex"].map { app.appending(path: $0) }
        }
        if let cli = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex.cli") {
            candidates.append(cli.appending(path: "Contents/MacOS/codex"))
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map { URL(fileURLWithPath: $0) }
        candidates.append(fm.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex"))
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appending(path: "codex")
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// All pipe reads and process cleanup run off the main actor and have a bounded lifetime.
    private static func read(from executable: URL) -> AgentUsage? {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            // Closing stdin normally ends app-server. Escalate only for this temporary child.
            let grace = min(deadline, ProcessInfo.processInfo.systemUptime + 0.2)
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
            if process.isRunning { process.terminate() }
            let termination = min(deadline, ProcessInfo.processInfo.systemUptime + 0.2)
            while process.isRunning && ProcessInfo.processInfo.systemUptime < termination { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        // A child that exits before initialize must not send SIGPIPE to the menu bar app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        func send(_ message: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
            data.append(0x0a)
            return (try? input.fileHandleForWriting.write(contentsOf: data)) != nil
        }
        guard send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "stayvibe", "version": "1.0"],
            "capabilities": ["experimentalApi": false]
        ]]) else { return nil }

        var pending = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var initialized = false
        let descriptor = output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < deadline {
            var state = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = Int32(max(1, min(100, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let ready = poll(&state, 1, remaining)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return nil }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count < 2 * 1024 * 1024 else { return nil }
            while let newline = pending.firstIndex(of: 0x0a) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if id == 1 && !initialized {
                    guard message["result"] != nil, message["error"] == nil,
                          send(["method": "initialized", "params": [:]]),
                          send(["id": 2, "method": "account/rateLimits/read",
                                "params": ["excludeResetCreditDetails": true]]) else { return nil }
                    initialized = true
                } else if id == 2 && initialized {
                    guard message["error"] == nil, let result = message["result"] as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: result) else { return nil }
                    return UsageParser.codexAccount(data: data)
                }
            }
        }
        return nil
    }
}
