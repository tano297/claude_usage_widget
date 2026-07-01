import AppIntents
import WidgetKit

/// The widget's refresh button. Tapping it asks the always-running agent to do a live fetch (via a
/// Darwin signal) and reloads the widget so the new snapshot renders. If the agent isn't running,
/// the reload still re-reads the last snapshot from disk.
struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Claude usage"
    static var description = IntentDescription("Fetch the latest Claude usage now.")

    func perform() async throws -> some IntentResult {
        RefreshSignal.post()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
