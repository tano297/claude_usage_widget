import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

/// Reads the snapshot the agent wrote to the App Group. The widget never touches the Keychain or
/// the network itself — the sandbox forbids reading Claude Code's Keychain item.
struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .placeholder())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        // Placeholder ONLY for the gallery preview; a real load miss must show the no-data state,
        // never fabricated numbers presented as current usage.
        let snap = context.isPreview ? .placeholder() : (SharedStore.load() ?? .noData())
        completion(UsageEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snap = SharedStore.load() ?? .noData()
        let now = Date()
        // Emit a handful of entries at 5-minute steps so the "resets in …" countdowns keep
        // ticking down between agent writes; request a reload after 15 minutes as a fallback.
        var entries: [UsageEntry] = []
        for step in 0..<6 {
            entries.append(UsageEntry(date: now.addingTimeInterval(Double(step) * 300), snapshot: snap))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }
}
