import CoreGraphics
import Darwin
import Foundation

final class SkyLightProbe {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias GetOverride = @convention(c) (Int32, CGDirectDisplayID) -> Bool
    private typealias SetOverride = @convention(c) (Int32, CGDirectDisplayID, Bool) -> Void

    private let handle: UnsafeMutableRawPointer
    private let connection: Int32
    private let getOverride: GetOverride
    private let setOverride: SetOverride

    init() throws {
        #if arch(arm64)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion == 27, version.minorVersion == 2, version.patchVersion == 1 else {
            throw ProbeError("The experimental SkyLight ABI was only checked on macOS 27.2.1 (arm64).")
        }
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_LOCAL | RTLD_NOW) else {
            throw ProbeError("Could not load SkyLight.")
        }
        guard let main = dlsym(handle, "SLSMainConnectionID"),
              let get = dlsym(handle, "SLSGetMenuBarVisibilityOverrideOnDisplay"),
              let set = dlsym(handle, "SLSSetMenuBarVisibilityOverrideOnDisplay") else {
            dlclose(handle)
            throw ProbeError("This system does not export the required SkyLight symbols.")
        }
        let connection = unsafeBitCast(main, to: MainConnection.self)()
        guard connection != 0 else {
            dlclose(handle)
            throw ProbeError("No WindowServer connection for this process.")
        }
        self.handle = handle
        self.connection = connection
        self.getOverride = unsafeBitCast(get, to: GetOverride.self)
        self.setOverride = unsafeBitCast(set, to: SetOverride.self)
        #else
        throw ProbeError("The experimental SkyLight ABI was only checked on macOS 27.2.1 (arm64).")
        #endif
    }

    deinit { dlclose(handle) }

    func isForcedVisible(_ display: CGDirectDisplayID) -> Bool {
        getOverride(connection, display)
    }

    func forceVisible(on display: CGDirectDisplayID, observe: () -> Void) throws {
        guard display != 0, CGDisplayIsActive(display) != 0, CGDisplayIsInMirrorSet(display) == 0 else {
            throw ProbeError("Use the ID of an active, non-mirrored display from `MenuBarProbe displays`.")
        }
        guard !isForcedVisible(display) else {
            print("Display \(display) already has a force-visible flag; left it alone.")
            return
        }
        setOverride(connection, display, true)
        defer { setOverride(connection, display, false) }
        observe()
    }
}
