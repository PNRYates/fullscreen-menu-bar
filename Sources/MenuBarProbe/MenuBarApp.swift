import AppKit
import SwiftUI

@MainActor
final class BarController: ObservableObject {
    @Published private(set) var settings: BarSettings
    @Published private(set) var status = "Waiting for a full-screen app"
    @Published private(set) var issue: String?

    private let store = UserDefaults.standard
    private let settingsKey = "BarSettings"
    private let reader = FocusedSpaceReader()
    private var playback = MediaPlaybackReader()
    private var session: VisibilitySession?
    private var visibility: FocusedVisibilityController?
    private var settling = SpaceRuleTiming()
    private var timer: Timer?

    init() {
        settings = store.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(BarSettings.self, from: $0) }
            ?? BarSettings()
    }

    func start() {
        do {
            // A previous run may have stopped before it could restore the Mac setting.
            let session = try VisibilitySession()
            _ = try session.recover()
            guard settings.enabled else {
                updateStatus("Rules paused")
                return
            }
            guard reader != nil else {
                throw ProbeError("Full-screen rules aren’t available on this Mac.")
            }
            self.session = session
            visibility = FocusedVisibilityController(trial: session.trial)
            settling = SpaceRuleTiming()
            issue = nil
            updateStatus("Waiting for a full-screen app")
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            fail(error)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settling = SpaceRuleTiming()
        visibility = nil
        if let session {
            do { _ = try session.recover() }
            catch { issue = "Couldn’t restore your Mac setting. Reopen Full Screen Bar to retry." }
        }
        session = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.enabled else { return }
        settings.enabled = enabled
        save()
        if enabled {
            start()
        } else {
            issue = nil
            stop()
            updateStatus("Rules paused")
        }
    }

    func setAutoHideDuringPlayback(_ enabled: Bool) {
        settings.autoHideDuringPlayback = enabled
        save()
    }

    func setDefault(_ mode: BarMode, for kind: DisplayKind) {
        settings.displays[kind] = mode
        save()
    }

    func setAppMode(_ mode: BarMode?, for id: String, kind: DisplayKind) {
        guard let index = settings.apps.firstIndex(where: { $0.id == id }) else { return }
        settings.apps[index].modes[kind] = mode
        save()
    }

    func addApp(at url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        addApp(id: id, name: name)
    }

    func addApp(id: String, name: String) {
        guard !settings.apps.contains(where: { $0.id == id }) else { return }
        settings.apps.append(.init(id: id, name: name))
        settings.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    func removeApp(_ id: String) {
        settings.apps.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { store.set(data, forKey: settingsKey) }
    }

    private func tick() {
        guard let session else { return }
        do {
            let time = ProcessInfo.processInfo.systemUptime
            let displays = reader?.singleDisplayFullScreenApps(in: settings.displayDependentAppIDs) ?? [:]
            let observation = reader?.observe() ?? .unresolved
            var scoped = settings.scopedVisibleExceptions(on: displays) { id in
                NSRunningApplication.runningApplications(withBundleIdentifier: id).contains {
                    playback.isPlaying(in: $0.processIdentifier, at: time)
                }
            }
            if case .fullScreen(let focus) = observation, let id = focus.window.bundleID,
               let kind = displays[id], (kind == .notched) != focus.window.notched {
                scoped.remove(id)
            }
            try session.appRules.update(scoped)
            guard settling.shouldApply(observation, at: time) else { return }
            switch observation {
            case .fullScreen(let focus):
                let window = focus.window
                let playing = settings.autoHideDuringPlayback && playback.isPlaying(in: focus.ownerPID, at: time)
                let mode = settings.mode(for: window.bundleID, notched: window.notched, playingMedia: playing)
                if let id = window.bundleID, session.appRules.prepared.contains(id) {
                    try session.appRules.check(id)
                    if let current = visibility?.current { try visibility?.update(current) }
                } else {
                    try visibility?.update(mode.visibility)
                }
                updateStatus("\(window.appName) · \(mode.title)\(playing ? " (playback)" : "")")
            case .desktop(let notched):
                let defaultMode = settings.mode(for: nil, notched: notched)
                try visibility?.update(defaultMode == .hide ? .hide : nil)
                updateStatus("Waiting for a full-screen app")
            case .unresolved:
                try visibility?.update(nil)
                updateStatus("Waiting for a full-screen app")
            }
        } catch {
            fail(error)
        }
    }

    private func updateStatus(_ text: String) {
        if status != text { status = text }
    }

    private func fail(_ error: Error) {
        settings.enabled = false
        save()
        issue = error.localizedDescription
        stop()
        updateStatus("Rules paused")
    }
}

@MainActor
private final class BarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = BarController()
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Full Screen Bar")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "▤" }
            button.toolTip = "Full Screen Bar"
            button.setAccessibilityLabel("Full Screen Bar")
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for (title, action, shortcut) in [
            ("Settings…", #selector(showSettings), ","),
            ("Pause Rules", #selector(toggleRules), ""),
            ("Quit Full Screen Bar", #selector(quit), "q"),
        ] {
            if shortcut == "q" { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
            entry.target = self
            menu.addItem(entry)
            if action == #selector(toggleRules) { toggleItem = entry }
        }
        item.menu = menu
        statusItem = item
        controller.start()
        if !UserDefaults.standard.bool(forKey: "HasOpenedSettings") {
            UserDefaults.standard.set(true, forKey: "HasOpenedSettings")
            showSettings()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleItem?.title = controller.settings.enabled ? "Pause Rules" : "Resume Rules"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleRules() { controller.setEnabled(!controller.settings.enabled) }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Full Screen Bar"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BarSettingsView(controller: controller, chooseApp: chooseApp))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func chooseApp() {
        guard let settingsWindow else { return }
        let panel = NSOpenPanel()
        panel.title = "Add an App"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.beginSheetModal(for: settingsWindow) { [weak self, panel] response in
            guard response == .OK, let url = panel.url else { return }
            self?.controller.addApp(at: url)
        }
    }
}

@MainActor
func runMenuBarApp() {
    let app = NSApplication.shared
    let delegate = BarAppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
