import Foundation

public enum RelativePath {
    /// Rejects absolute paths and any `..` segment so a saved asset cannot escape the home folder.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if path.hasPrefix("/") || path.hasPrefix("~") { return false }
        if path.contains("\\") || path.contains("\0") { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return false }
        return true
    }

    /// Resolves `relative` inside `homeDirectory`, or returns nil when the path is unsafe.
    public static func resolve(homeDirectory: URL, relative: String) -> URL? {
        guard isSafe(relative) else { return nil }
        var url = homeDirectory
        for part in relative.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        let home = homeDirectory.standardizedFileURL
        let resolved = url.standardizedFileURL
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        guard resolved.path == home.path || resolved.path.hasPrefix(prefix) else { return nil }
        return url
    }
}
