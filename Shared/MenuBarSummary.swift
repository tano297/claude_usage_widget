import Foundation

// MARK: - Menu bar summary

/// Compact all-windows readout for the menu bar label: one labeled integer percent per active
/// limit, e.g. "S0 W27 F45" — Session, Weekly, then each model-scoped weekly window in snapshot
/// order. Scoped windows are labeled by the first letter of the model name; on a collision with
/// an already-used label (S and W are taken) the label falls back to the first two characters,
/// so a future "Sonnet" renders as "So" rather than shadowing Session.
public func menuBarSummary(_ snapshot: UsageSnapshot?) -> String {
    guard let s = snapshot else { return "—" }

    var items: [(label: String, bar: LimitBar)] = []
    var usedLabels = Set<String>()
    func add(_ preferred: String, _ fallback: String, _ bar: LimitBar?) {
        guard let bar else { return }
        let label = usedLabels.contains(preferred) ? fallback : preferred
        usedLabels.insert(label)
        items.append((label, bar))
    }

    add("S", "Se", s.session)
    add("W", "We", s.weeklyAll)
    for scoped in s.weeklyScoped ?? [] {
        let name = scoped.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        add(String(name.prefix(1)).uppercased(),
            String(name.prefix(2)).capitalized,
            scoped.bar)
    }

    guard !items.isEmpty else { return "—" }
    return items.map { "\($0.label)\(Int($0.bar.percent.rounded()))" }.joined(separator: " ")
}
