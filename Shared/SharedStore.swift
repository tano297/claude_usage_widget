import Foundation

/// The agent writes one minimal JSON snapshot; the sandboxed widget has read-only access to this
/// one Application Support directory. App Groups are avoided so local signing works with a free
/// Apple developer team.
public enum SharedStore {
    static let subdir = "ClaudeUsage"
    static let filename = "usage.json"

    /// The user's REAL home directory — even inside the widget's sandbox, where Foundation's home
    /// APIs return the container. `getpwuid` is permitted in the sandbox and yields the true path,
    /// so both processes agree on one absolute file location.
    static func realHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func directory() -> URL {
        realHome().appendingPathComponent("Library/Application Support/\(subdir)", isDirectory: true)
    }

    static var fileURL: URL { directory().appendingPathComponent(filename) }

    static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
    static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    /// Called by the agent only (the widget's sandbox exception is read-only).
    public static func save(_ snapshot: UsageSnapshot) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory(),
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory().path)
        let data = try makeEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? makeDecoder().decode(UsageSnapshot.self, from: data)
    }
}

/// Widget kinds, so the agent can reload one widget without the other.
public enum WidgetKind {
    public static let current = "ClaudeUsageWidget"
    public static let accounts = "ClaudeAccountsWidget"
}
