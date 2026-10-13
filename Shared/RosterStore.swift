import Foundation

/// `roster.json` sits beside `usage.json`. It holds emails and meters only. Refresh tokens live in
/// the Keychain and are written by the agent, never by this type.
public enum RosterStore {
    public static let filename = "roster.json"

    /// Tests point this at a temporary directory. The app and the widget leave it nil.
    public static var directoryOverride: URL?

    public static func fileURL() -> URL {
        let directory = directoryOverride ?? SharedStore.directory()
        return directory.appendingPathComponent(filename)
    }

    public static func load() -> RosterSnapshot {
        guard let data = try? Data(contentsOf: fileURL()) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RosterSnapshot.self, from: data)) ?? .empty
    }

    /// Called by the agent only. The widget's sandbox exception is read-only.
    public static func save(_ snapshot: RosterSnapshot) throws {
        let directory = directoryOverride ?? SharedStore.directory()
        let manager = FileManager.default
        try manager.createDirectory(at: directory,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
