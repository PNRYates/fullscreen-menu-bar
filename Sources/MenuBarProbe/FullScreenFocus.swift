import AppKit
import ApplicationServices

struct FullScreenFocus: Equatable {
    let appName: String
    let bundleID: String?
    let displayID: CGDirectDisplayID
    let displayName: String
    let notched: Bool

    var description: String {
        "\(appName) (\(bundleID ?? "no bundle ID")) on \(displayName) [\(displayID), \(notched ? "notched" : "no notch")]"
    }

    @MainActor
    static func current() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let focusedWindow = attribute("AXFocusedWindow", of: application),
              CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else { return nil }
        let window = focusedWindow as! AXUIElement
        guard attribute("AXFullScreen", of: window) as? Bool == true,
              let position = axValue("AXPosition", of: window, type: .cgPoint),
              let size = axValue("AXSize", of: window, type: .cgSize) else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        let windowBounds = CGRect(origin: origin, size: dimensions)
        var bestArea: CGFloat = 0
        var bestDisplay: (CGDirectDisplayID, NSScreen)?
        for (id, screen) in displays() {
            let overlap = windowBounds.intersection(CGDisplayBounds(id))
            guard !overlap.isNull, overlap.width * overlap.height > bestArea else { continue }
            bestArea = overlap.width * overlap.height
            bestDisplay = (id, screen)
        }
        guard let (id, screen) = bestDisplay else { return nil }
        return Self(appName: app.localizedName ?? app.bundleIdentifier ?? "Unknown app",
                    bundleID: app.bundleIdentifier, displayID: id, displayName: screen.localizedName,
                    notched: screen.safeAreaInsets.top > 0)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axValue(_ name: String, of element: AXUIElement, type: AXValueType) -> AXValue? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        return AXValueGetType(ax) == type ? ax : nil
    }
}

func requireAccessibility() throws {
    guard AXIsProcessTrusted() else {
        throw ProbeError("Enable Accessibility access for the app launching MenuBarProbe in System Settings > Privacy & Security > Accessibility, then restart the command.")
    }
}

@MainActor
func watchFocus(rules: FocusRules, trial: VisibilityTrial, stop: DispatchSemaphore) throws -> VisibilityTrial.Outcome {
    var controller = FocusedVisibilityController(trial: trial)
    var previousObservation: FullScreenFocus?
    var stableFocus: FullScreenFocus?
    let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in }
    defer { timer.invalidate() }

    print("Watching native full-screen windows. Ctrl-C stops and restores the setting.")
    fflush(nil)
    return try trial.withCleanup {
        while stop.wait(timeout: .now()) == .timedOut {
            let observation = FullScreenFocus.current()
            if observation == previousObservation {
                let desired = observation.flatMap { rules.visibility(for: $0.bundleID, notched: $0.notched) }
                try controller.update(desired)
                if observation != stableFocus {
                    if let focus = observation {
                        print("\(focus.description): \(desired?.rawValue ?? "system setting")")
                    } else {
                        print("No focused native full-screen window: system setting")
                    }
                    fflush(nil)
                    stableFocus = observation
                }
            }
            previousObservation = observation
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
    }
}
