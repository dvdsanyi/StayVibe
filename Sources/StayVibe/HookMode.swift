import Darwin
import Foundation
import StayVibeCore

/// `StayVibe --hook claude|codex`: what Claude Code and Codex run for each hook.
/// Forwards the event to the running app and exits 0 without output, so it can never
/// block, slow down or change the agent's behavior.
enum HookMode {
    static func run(agent name: String) -> Never {
        let agent = Agent(rawValue: name) ?? .claude
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        if var event = HookEvent(agent: agent, payload: payload) {
            let chain = ancestors()
            let agentIndex = chain.firstIndex { isAgentBinary($0.path) }
            event.agentPID = agentIndex.map { chain[$0].pid }
            event.hostBundleID = chain.dropFirst((agentIndex ?? -1) + 1).lazy.compactMap { appBundleID($0.path) }.first
            if !EventSocket.send(event) {
                Power.setClamshellSleep(disabled: false)  // app not running: never leave the Mac unable to sleep
            }
        }
        exit(0)
    }

    private struct Proc { let pid: Int32; let path: String }

    /// Parent processes, nearest first: shell → claude/codex → … → host app.
    private static func ancestors() -> [Proc] {
        var chain: [Proc] = []
        var pid = getppid()
        while pid > 1, chain.count < 40 {
            var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let n = proc_pidpath(pid, &path, UInt32(path.count))
            chain.append(Proc(pid: pid, path: String(decoding: path.prefix(Int(max(n, 0))), as: UTF8.self)))
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            pid = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? Int32(info.pbi_ppid) : 0
        }
        return chain
    }

    private static func isAgentBinary(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "claude" || name.hasPrefix("codex")
    }

    /// The outermost `.app` a process lives in (helpers sit deep inside their app's bundle).
    private static func appBundleID(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
    }
}
