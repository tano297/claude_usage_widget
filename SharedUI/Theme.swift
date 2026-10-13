import SwiftUI

enum ClaudeTheme {
    /// Anthropic's official "clay" swatch (#D97757), used as the provider identity color.
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
}

/// Usage fill. Under 34% is green, 34–66% is orange, 67% and up is red.
public func usagePercentColor(_ percent: Double) -> Color {
    if percent < 34 { return .green }
    if percent < 67 { return .orange }
    return .red
}

extension Severity {
    var showsWarningGlyph: Bool {
        self == .warning || self == .high || self == .critical
    }
}
