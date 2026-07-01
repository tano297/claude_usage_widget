import Foundation

/// Shared snapshot store. The non-sandboxed agent writes `usage.json` under the user's real
/// Application Support directory; the sandboxed widget reads that same absolute path through a
/// read-only *temporary-exception* sandbox entitlement (see ClaudeUsageWidget.entitlements).
///
/// This deliberately avoids App Groups, which on macOS now require registering the group id on
/// the Apple Developer portal — i.e. a *paid* membership. A read-only path exception is honored
/// by local development signing, so a **free personal team** is enough.
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
        try FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
        let data = try makeEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? makeDecoder().decode(UsageSnapshot.self, from: data)
    }
}
