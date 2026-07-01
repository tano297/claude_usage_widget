import SwiftUI

// Colors mirror the claude.ai usage panel: blue when healthy, amber at warning (the 81% case
// in the screenshot), escalating to red. Compiled into both the app and widget targets.
extension Severity {
    var color: Color {
        switch self {
        case .normal:   return Color(red: 0.30, green: 0.55, blue: 0.98) // blue
        case .warning:  return Color(red: 0.95, green: 0.68, blue: 0.22) // amber
        case .high:     return Color(red: 0.95, green: 0.45, blue: 0.15) // orange
        case .critical: return Color(red: 0.90, green: 0.26, blue: 0.24) // red
        case .unknown:  return Color.gray
        }
    }

    var showsWarningGlyph: Bool {
        self == .warning || self == .high || self == .critical
    }
}
