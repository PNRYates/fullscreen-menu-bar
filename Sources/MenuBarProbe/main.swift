import AppKit
import Darwin
import Foundation

private enum FullScreenPreference {
    static let key = "AppleMenuBarVisibleInFullscreen"
    static let notification = Notification.Name("AppleInterfaceFullScreenMenuBarVisibilityChangedNotification")

    static func read(domain: CFString) throws -> Bool? {
        try synchronise(domain)
        guard let value = CFPreferencesCopyValue(key as CFString, domain,
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return nil
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool else {
            throw ProbeError("The full-screen menu bar preference is not a Boolean; leaving it alone.")
        }
        return boolean
    }

    static func write(_ value: Bool?, domain: CFString) throws {
        CFPreferencesSetValue(key as CFString, value.map { $0 as CFBoolean }, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try synchronise(domain)
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    private static func synchronise(_ domain: CFString) throws {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser,
                                       kCFPreferencesAnyHost) else {
            throw ProbeError("Could not synchronise global preferences.")
        }
    }
}

@MainActor
func displays() -> [(CGDirectDisplayID, NSScreen)] {
    NSScreen.screens.compactMap { screen in
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return (id, screen)
    }
}

@MainActor
func listDisplays() {
    for (id, screen) in displays() {
        let connection = CGDisplayIsBuiltin(id) != 0 ? "built-in" : "external"
        let cutout = screen.safeAreaInsets.top > 0 ? "notched" : "no notch"
        print("\(id)\t\(screen.localizedName)\t\(connection), \(cutout)\t\(Int(screen.frame.width))×\(Int(screen.frame.height)) pt")
    }
}

final class VisibilitySession {
    let trial: VisibilityTrial
    let appRules: AppVisibilityRules
    private let fd: Int32

    init() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("FullscreenMenuBarProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ProbeError("Couldn’t open the menu bar settings.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ProbeError("Another menu bar test is running. Stop it before turning on rules.")
        }
        self.fd = fd
        trial = VisibilityTrial(journal: directory.appendingPathComponent("global-test.json"),
                                read: { try FullScreenPreference.read(domain: kCFPreferencesAnyApplication) },
                                write: { try FullScreenPreference.write($0, domain: kCFPreferencesAnyApplication) })
        appRules = AppVisibilityRules(directory: directory, read: { id in
            try FullScreenPreference.read(domain: id as CFString)
        }, write: { id, value in
            try FullScreenPreference.write(value, domain: id as CFString)
        })
    }

    deinit { close(fd) }

    func recover() throws -> VisibilityTrial.Outcome? {
        let global = Result { try trial.recover() }
        try appRules.recover()
        return try global.get()
    }
}

func withTrial<T>(_ action: (VisibilityTrial) throws -> T) throws -> T {
    let session = try VisibilitySession()
    return try withExtendedLifetime(session) { try action(session.trial) }
}

func withSignalWaiter<T>(_ action: (DispatchSemaphore) throws -> T) rethrows -> T {
    let stop = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "MenuBarProbe.signals")
    let sources = [SIGINT, SIGTERM, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler { stop.signal() }
        source.activate()
        return source
    }
    defer { sources.forEach { $0.cancel() } }
    return try action(stop)
}

func report(_ outcome: VisibilityTrial.Outcome?) {
    switch outcome {
    case .restored: print("Original full-screen preference restored.")
    case .changedElsewhere: print("The preference changed during the test. Left it alone.")
    case .noChange: print("No restore needed.")
    case nil: print("No pending recovery record.")
    }
}

let usage = """
Usage: MenuBarProbe displays
       MenuBarProbe status
       MenuBarProbe focused
       MenuBarProbe watch [rules.json]
       MenuBarProbe global <show|hide> [seconds]
       MenuBarProbe recover
       MenuBarProbe skylight status
       MenuBarProbe skylight show <display-id> [seconds]

A test lasts 20 seconds by default (1–120). Ctrl-C ends it early.
SkyLight is experimental and can only attempt to force the menu bar visible.
"""

@MainActor
func run(_ arguments: [String]) throws {
    switch arguments.first {
    case "--app":
        runMenuBarApp()
    case nil where Bundle.main.bundleIdentifier == "net.peteryates.fullscreenbar":
        runMenuBarApp()
    case "displays" where arguments.count == 1:
        listDisplays()
    case "status" where arguments.count == 1:
        if let visible = try FullScreenPreference.read(domain: kCFPreferencesAnyApplication) {
            print("Stored full-screen preference: \(visible ? "show" : "auto-hide")")
        } else {
            print("Stored full-screen preference: unset")
        }
    case "focused" where arguments.count == 1:
        try requireAccessibility()
        print(FullScreenFocus.current()?.description ?? "No focused native full-screen window")
    case "watch" where (1...2).contains(arguments.count):
        try requireAccessibility()
        let rules: FocusRules
        if let path = arguments.dropFirst().first {
            rules = try JSONDecoder().decode(FocusRules.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            rules = .builtIn
        }
        try withTrial { trial in
            try withSignalWaiter { stop in
                report(try watchFocus(rules: rules, trial: trial, stop: stop))
            }
        }
    case "global" where (2...3).contains(arguments.count):
        let mode = arguments[1]
        let duration = arguments.count == 3 ? Int(arguments[2]) : 20
        guard ["show", "hide"].contains(mode), let duration, (1...120).contains(duration) else {
            throw ProbeError(usage)
        }
        try withTrial { trial in
            try withSignalWaiter { stop in
                report(try trial.run(mode == "show") {
                    print("Global full-screen mode: \(mode), for \(duration)s. Move the pointer away from the top edge to observe it.")
                    fflush(nil)
                    _ = stop.wait(timeout: .now() + .seconds(duration))
                })
            }
        }
    case "recover" where arguments.count == 1:
        report(try VisibilitySession().recover())
    case "skylight" where arguments == ["skylight", "status"]:
        let skyLight = try SkyLightProbe()
        for (id, screen) in displays() {
            let state = skyLight.isForcedVisible(id) ? "set" : "not set or unavailable"
            print("\(id)\t\(screen.localizedName)\tforce-visible flag: \(state)")
        }
    case "skylight" where (3...4).contains(arguments.count) && arguments[1] == "show":
        let duration = arguments.count == 4 ? Int(arguments[3]) : 20
        guard let display = CGDirectDisplayID(arguments[2]), let duration, (1...120).contains(duration) else {
            throw ProbeError(usage)
        }
        let skyLight = try SkyLightProbe()
        try withSignalWaiter { stop in
            try skyLight.forceVisible(on: display) {
                print("Requested force-visible on display \(display) for \(duration)s. Observe the menu bar on both screens.")
                fflush(nil)
                _ = stop.wait(timeout: .now() + .seconds(duration))
            }
        }
    case nil, "-h", "--help":
        print(usage)
    default:
        throw ProbeError(usage)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
