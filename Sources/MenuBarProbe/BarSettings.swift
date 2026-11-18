import Foundation

enum BarMode: String, CaseIterable, Codable {
    case show, hide, system

    var title: String {
        switch self {
        case .show: "Keep Visible"
        case .hide: "Auto-Hide"
        case .system: "Use Mac Setting"
        }
    }

    var visibility: MenuBarVisibility? {
        switch self {
        case .show: .show
        case .hide: .hide
        case .system: nil
        }
    }
}

enum DisplayKind: CaseIterable {
    case notched, unnotched

    var title: String {
        switch self {
        case .notched: "Screen with a camera notch"
        case .unnotched: "Screen without a notch"
        }
    }
}

struct DisplayRules: Codable {
    var notched: BarMode?
    var unnotched: BarMode?

    subscript(kind: DisplayKind) -> BarMode? {
        get { kind == .notched ? notched : unnotched }
        set {
            if kind == .notched { notched = newValue }
            else { unnotched = newValue }
        }
    }
}

struct BarSettings: Codable {
    struct AppRule: Codable, Identifiable {
        let id: String
        let name: String
        var modes = DisplayRules()
    }

    var enabled = true
    var displays = DisplayRules(notched: .show, unnotched: .hide)
    var apps: [AppRule] = []

    func mode(for bundleID: String?, notched: Bool) -> BarMode {
        let kind: DisplayKind = notched ? .notched : .unnotched
        return apps.first { $0.id == bundleID }?.modes[kind] ?? displays[kind] ?? .system
    }
}
