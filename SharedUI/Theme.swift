import SwiftUI

enum ClaudeTheme {
    /// Anthropic's official "clay" swatch (#D97757), used as the provider identity color.
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
}

// Start with Anthropic clay for healthy usage, then move through stronger warm tones as a limit
// approaches exhaustion. Compiled into both the app and widget targets.
extension Severity {
    var color: Color {
        switch self {
        case .normal:   return ClaudeTheme.clay
        case .warning:  return Color(red: 0.88, green: 0.54, blue: 0.24) // amber-orange
        case .high:     return Color(red: 0.85, green: 0.36, blue: 0.17) // deep orange
        case .critical: return Color(red: 0.78, green: 0.20, blue: 0.18) // warm red
        case .unknown:  return Color.gray
        }
    }

    var showsWarningGlyph: Bool {
        self == .warning || self == .high || self == .critical
    }
}
