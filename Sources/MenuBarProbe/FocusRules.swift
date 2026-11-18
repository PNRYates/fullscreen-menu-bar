import Foundation

enum MenuBarVisibility: String, Codable {
    case show, hide

    var isVisible: Bool { self == .show }
}

struct FocusRules: Decodable {
    struct Rule: Decodable {
        var all: MenuBarVisibility?
        var notched: MenuBarVisibility?
        var unnotched: MenuBarVisibility?

        func visibility(notched displayHasNotch: Bool) -> MenuBarVisibility? {
            (displayHasNotch ? notched : unnotched) ?? all
        }
    }

    let defaults: Rule
    let apps: [String: Rule]?

    static let builtIn = FocusRules(defaults: Rule(notched: .show, unnotched: .hide), apps: nil)

    func visibility(for bundleID: String?, notched: Bool) -> MenuBarVisibility? {
        bundleID.flatMap { apps?[$0]?.visibility(notched: notched) } ?? defaults.visibility(notched: notched)
    }
}

struct FocusedVisibilityController {
    let trial: VisibilityTrial
    private(set) var current: MenuBarVisibility?

    mutating func update(_ desired: MenuBarVisibility?) throws {
        if let current, try trial.read() != current.isVisible {
            throw ProbeError("Your Mac’s menu bar setting changed. Rules paused so your change stays in place.")
        }
        guard desired != current else { return }
        let outcome = try desired.map { try trial.switchTo($0.isVisible) } ?? trial.recover()
        if outcome == .changedElsewhere {
            throw ProbeError("Your Mac’s menu bar setting changed. Rules paused so your change stays in place.")
        }
        current = desired
    }
}
