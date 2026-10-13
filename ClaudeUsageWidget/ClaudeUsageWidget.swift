import WidgetKit
import SwiftUI

@main
struct ClaudeUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
        ClaudeAccountsWidget()
    }
}

struct ClaudeUsageWidget: Widget {
    let kind = WidgetKind.current

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Current sub")
        .description("The account signed in to Claude Code.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
