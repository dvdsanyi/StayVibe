import Foundation

/// VS Code-family editors record their open windows in `User/globalStorage/storage.json`.
/// Opening a folder focuses the window that already has it, but opens a new window otherwise,
/// so StayVibe only opens a folder that some window already shows.
public enum EditorWindows {
    /// Application Support folder name per editor bundle ID.
    static let supportFolders = [
        "com.microsoft.VSCode": "Code", "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.vscodium": "VSCodium", "com.exafunction.windsurf": "Windsurf",
    ]

    /// The most specific folder open in a window that contains `cwd`, if any.
    public static func folder(containing cwd: String, storage: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: storage) as? [String: Any],
              let state = json["windowsState"] as? [String: Any] else { return nil }
        let windows = (state["openedWindows"] as? [[String: Any]] ?? []) + [state["lastActiveWindow"] as? [String: Any] ?? [:]]
        return windows.compactMap { ($0["folder"] as? String).flatMap(URL.init(string:)) }
            .filter { cwd == $0.path || cwd.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    public static func folder(containing cwd: String, editor bundleID: String,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let name = supportFolders[bundleID],
              let data = try? Data(contentsOf: home.appending(path: "Library/Application Support/\(name)/User/globalStorage/storage.json"))
        else { return nil }
        return folder(containing: cwd, storage: data)
    }
}
