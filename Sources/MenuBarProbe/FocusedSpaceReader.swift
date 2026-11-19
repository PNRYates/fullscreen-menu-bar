import AppKit
import Darwin

struct SpaceRuleTiming {
    private var previous: FocusedSpaceReader.Observation?
    private var since: TimeInterval = 0

    mutating func shouldApply(_ observation: FocusedSpaceReader.Observation, at time: TimeInterval) -> Bool {
        if observation != previous {
            previous = observation
            since = time
        }
        switch observation {
        case .fullScreen: return true
        case .desktop: return time - since >= 0.35
        case .unresolved: return time - since >= 0.75
        }
    }
}

/// Read-only WindowServer queries. The window list corroborates the fullscreen host;
/// its stacking order and window size are not used to detect fullscreen.
@MainActor
final class FocusedSpaceReader {
    private typealias Connection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    private typealias ScreenForSpace = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
    private typealias ManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private let handle: UnsafeMutableRawPointer
    private let connection: Int32
    private let activeSpace: ActiveSpace
    private let spaceType: SpaceType
    private let screenForSpace: ScreenForSpace
    private let managedSpaces: ManagedSpaces

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                                  RTLD_LOCAL | RTLD_NOW) else { return nil }
        guard let connect = dlsym(handle, "SLSMainConnectionID"),
              let active = dlsym(handle, "SLSGetActiveSpace"),
              let type = dlsym(handle, "SLSSpaceGetType"),
              let screen = dlsym(handle, "SLSCopyManagedDisplayForSpace"),
              let spaces = dlsym(handle, "SLSCopyManagedDisplaySpaces") else {
            dlclose(handle)
            return nil
        }
        let connection = unsafeBitCast(connect, to: Connection.self)()
        guard connection != 0 else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.connection = connection
        activeSpace = unsafeBitCast(active, to: ActiveSpace.self)
        spaceType = unsafeBitCast(type, to: SpaceType.self)
        screenForSpace = unsafeBitCast(screen, to: ScreenForSpace.self)
        managedSpaces = unsafeBitCast(spaces, to: ManagedSpaces.self)
    }

    isolated deinit { dlclose(handle) }

    struct Focus: Equatable {
        let spaceID: UInt64
        let windowID: CGWindowID
        let ownerPID: pid_t
        let window: FullScreenFocus
    }

    enum Observation: Equatable {
        case fullScreen(Focus)
        case desktop(notched: Bool)
        case unresolved
    }

    func observe() -> Observation {
        let id = activeSpace(connection)
        guard id != 0 else { return .unresolved }
        switch spaceType(connection, id) {
        case 4:
            if let focus = current(), focus.spaceID == id { return .fullScreen(focus) }
        case 0:
            if let (_, screen) = display(for: id, containing: nil), activeSpace(connection) == id {
                return .desktop(notched: screen.safeAreaInsets.top > 0)
            }
        default:
            break
        }
        return .unresolved
    }

    func singleDisplayFullScreenApps(in bundleIDs: Set<String>) -> [String: DisplayKind] {
        guard !bundleIDs.isEmpty,
              let groups = managedSpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var ownership: [String: [DisplayKind?]] = [:]
        for group in groups {
            guard let spaces = group["Spaces"] as? [[String: Any]] else { return [:] }
            for space in spaces {
                guard let id = space["ManagedSpaceID"] as? UInt64 else { return [:] }
                guard spaceType(connection, id) == 4 else { continue }
                guard let layout = space["TileLayoutManager"] as? [String: Any],
                      let tiles = layout["TileSpaces"] as? [[String: Any]], tiles.count == 1,
                      let pid = space["pid"] as? pid_t,
                      let app = NSRunningApplication(processIdentifier: pid),
                      let bundleID = app.bundleIdentifier else { return [:] }
                guard bundleIDs.contains(bundleID) else { continue }
                let kind: DisplayKind?
                if let wid = space["fs_wid"] as? CGWindowID, wid != 0,
                   tiles[0]["TileWindowID"] as? CGWindowID == wid,
                   let (displayID, screen) = display(for: id, containing: nil),
                   !NSScreen.screensHaveSeparateSpaces || (group["Display Identifier"] as? String).flatMap(Self.displayID(for:)) == displayID {
                    kind = screen.safeAreaInsets.top > 0 ? .notched : .unnotched
                } else {
                    kind = nil
                }
                ownership[bundleID, default: []].append(kind)
            }
        }
        return Self.unambiguousDisplays(in: ownership)
    }

    nonisolated static func unambiguousDisplays(in ownership: [String: [DisplayKind?]]) -> [String: DisplayKind] {
        ownership.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private func current() -> Focus? {
        let id = activeSpace(connection)
        guard id != 0, spaceType(connection, id) == 4,
              let app = NSWorkspace.shared.frontmostApplication,
              let groups = managedSpaces(connection)?.takeRetainedValue() as? [[String: Any]],
              let group = groups.first(where: { group in
                  let current = group["Current Space"] as? [String: Any]
                  return current?["ManagedSpaceID"] as? UInt64 == id
              }),
              let spaces = group["Spaces"] as? [[String: Any]],
              let space = spaces.first(where: { $0["ManagedSpaceID"] as? UInt64 == id }),
              let layout = space["TileLayoutManager"] as? [String: Any],
              let tiles = layout["TileSpaces"] as? [[String: Any]], tiles.count == 1,
              let windowID = space["fs_wid"] as? CGWindowID, windowID != 0,
              tiles[0]["TileWindowID"] as? CGWindowID == windowID,
              space["pid"] as? pid_t == app.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let window = windows.first, window[kCGWindowNumber as String] as? CGWindowID == windowID,
              window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
              window[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let (displayID, screen) = display(for: id, containing: rect),
              activeSpace(connection) == id,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }

        return Focus(spaceID: id, windowID: windowID, ownerPID: app.processIdentifier, window: FullScreenFocus(
            appName: app.localizedName ?? app.bundleIdentifier ?? "App", bundleID: app.bundleIdentifier,
            displayID: displayID, displayName: screen.localizedName, notched: screen.safeAreaInsets.top > 0
        ))
    }

    private static func displayID(for identifier: String) -> CGDirectDisplayID? {
        if identifier == "Main" { return CGMainDisplayID() }
        guard let uuid = CFUUIDCreateFromString(nil, identifier as CFString) else { return nil }
        return CGDisplayGetDisplayIDFromUUID(uuid)
    }

    private func display(for spaceID: UInt64, containing window: CGRect?) -> (CGDirectDisplayID, NSScreen)? {
        let screens = displays().filter { CGDisplayIsActive($0.0) != 0 && CGDisplayIsInMirrorSet($0.0) == 0 }
        if NSScreen.screensHaveSeparateSpaces {
            guard let uuid = screenForSpace(connection, spaceID)?.takeRetainedValue(),
                  let id = Self.displayID(for: uuid as String) else { return nil }
            return screens.first { screenID, _ in
                screenID == id && (window.map { !$0.intersection(CGDisplayBounds(id)).isEmpty } ?? true)
            }
        }

        // With shared Spaces the Space identifies the main display, not the window's physical screen.
        guard let window else { return screens.count == 1 ? screens.first : nil }
        return screens.first { id, _ in
            let overlap = window.intersection(CGDisplayBounds(id))
            return !overlap.isEmpty && overlap.width * overlap.height > window.width * window.height / 2
        }
    }
}
