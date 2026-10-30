import Foundation

/// Offline fallback when Codex cannot return live account limits. A resumed conversation may be
/// months older than a newly created one, so filenames and directory dates cannot rank its usage.
public enum CodexUsageLogs {
    public static func latest(in root: URL) -> AgentUsage? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return nil }
        let logs = files.compactMap { item -> (URL, Date)? in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        var newest: AgentUsage?
        for (url, modified) in logs {
            // An unmodified older file cannot contain a later measurement. Read equally recent files too.
            if let newest, modified < newest.updated { break }
            guard let tail = Transcript.tail(of: url.path, bytes: 256 * 1024),
                  let candidate = UsageParser.codex(logTail: tail, updated: modified) else { continue }
            if candidate.updated > newest?.updated ?? .distantPast { newest = candidate }
        }
        return newest
    }
}
