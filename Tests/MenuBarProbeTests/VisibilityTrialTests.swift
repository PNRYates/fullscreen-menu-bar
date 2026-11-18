import Foundation
import XCTest
@testable import MenuBarProbe

final class VisibilityTrialTests: XCTestCase {
    func testRestoresUnsetAndExplicitValues() throws {
        for original: Bool? in [nil, true, false] {
            try withTrial(original) { trial, preference in
                let applied = !(original ?? true)
                let outcome = try trial.run(applied) {
                    XCTAssertEqual(preference.value, applied)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: trial.journal.path))
                }
                XCTAssertEqual(outcome, .restored)
                XCTAssertEqual(preference.writes, [applied, original])
                XCTAssertNil(try trial.recover())
            }
        }
    }

    func testLeavesAnExternalChangeAlone() throws {
        try withTrial(true) { trial, preference in
            let outcome = try trial.run(false) { preference.value = nil }
            XCTAssertEqual(outcome, .changedElsewhere)
            XCTAssertEqual(preference.writes, [false])
            XCTAssertNil(preference.value)
        }
    }

    func testRestoresAfterAnError() throws {
        try withTrial(false) { trial, preference in
            XCTAssertThrowsError(try trial.run(true) { throw ProbeError("test error") })
            XCTAssertEqual(preference.writes, [true, false])
            XCTAssertNil(try trial.recover())
        }
    }

    func testCrashRecordCanBeRecoveredAndBlocksNewRuns() throws {
        try withTrial(true) { trial, preference in
            try JSONEncoder().encode(VisibilityTrial.Snapshot(original: nil, applied: true)).write(to: trial.journal)
            XCTAssertThrowsError(try trial.run(false) { XCTFail("Should not start") })
            XCTAssertEqual(try trial.recover(), .restored)
            XCTAssertEqual(preference.writes, [nil])
            XCTAssertNil(try trial.recover())
        }
    }

    func testAlreadySetDoesNotWrite() throws {
        try withTrial(true) { trial, preference in
            XCTAssertEqual(try trial.run(true) { XCTFail("No change to observe") }, .noChange)
            XCTAssertTrue(preference.writes.isEmpty)
            XCTAssertNil(try trial.recover())
        }
    }

    func testWatcherFollowsFocusAndRestoresOnDesktopOrExit() throws {
        try withTrial(true) { trial, preference in
            let outcome = try trial.withCleanup {
                var controller = FocusedVisibilityController(trial: trial)
                try controller.update(.hide)
                try controller.update(.hide)
                try controller.update(.show)
                try controller.update(.hide)
                try controller.update(nil)
                try controller.update(.hide)
            }
            XCTAssertEqual(outcome, .restored)
            XCTAssertEqual(preference.writes, [false, true, false, true, false, true])
        }
    }

    func testChangingRulesDoesNotRestoreUnsetBetweenWrites() throws {
        try withTrial(nil) { trial, preference in
            let outcome = try trial.withCleanup {
                var controller = FocusedVisibilityController(trial: trial)
                try controller.update(.hide)
                try controller.update(.show)
                try controller.update(.hide)
            }
            XCTAssertEqual(outcome, .restored)
            XCTAssertEqual(preference.writes, [false, true, false, nil])
        }
    }

    func testRecoveryDuringAnOverrideSwitchAcceptsEitherAppliedValue() throws {
        for applied in [false, true] {
            try withTrial(applied) { trial, preference in
                let snapshot = VisibilityTrial.Snapshot(original: nil, applied: true, previousApplied: false)
                try JSONEncoder().encode(snapshot).write(to: trial.journal)
                XCTAssertEqual(try trial.recover(), .restored)
                XCTAssertNil(preference.value)
            }
        }
    }

    func testSpaceTransitionDoesNotBrieflyRestoreMacSetting() {
        var timing = SpaceRuleTiming()
        XCTAssertFalse(timing.shouldApply(.unresolved, at: 1))
        XCTAssertFalse(timing.shouldApply(.unresolved, at: 1.5))
        XCTAssertFalse(timing.shouldApply(.desktop(notched: false), at: 1.6))
        XCTAssertFalse(timing.shouldApply(.desktop(notched: false), at: 1.8))
        let window = FullScreenFocus(appName: "Example", bundleID: nil, displayID: 1, displayName: "Example", notched: false)
        XCTAssertTrue(timing.shouldApply(.fullScreen(.init(spaceID: 3, windowID: 4, ownerPID: 5, window: window)), at: 1.9))
        XCTAssertFalse(timing.shouldApply(.unresolved, at: 2))
        XCTAssertTrue(timing.shouldApply(.unresolved, at: 2.8))
        XCTAssertFalse(timing.shouldApply(.desktop(notched: false), at: 3))
        XCTAssertTrue(timing.shouldApply(.desktop(notched: false), at: 3.4))
    }

    func testWatcherStopsWhenTheUserChangesSettings() throws {
        try withTrial(true) { trial, preference in
            XCTAssertThrowsError(try trial.withCleanup {
                var controller = FocusedVisibilityController(trial: trial)
                try controller.update(.hide)
                preference.value = true
                try controller.update(.hide)
            })
            XCTAssertEqual(preference.writes, [false])
            XCTAssertEqual(preference.value, true)
            XCTAssertNil(try trial.recover())
        }
    }

    func testRulesPreferAppAndDisplayOverAppAndDefaults() throws {
        let data = Data("""
        {
            "defaults": {"notched": "show", "unnotched": "hide"},
            "apps": {
                "app.override": {"all": "show", "notched": "hide"},
                "app.partial": {"notched": "hide"}
            }
        }
        """.utf8)
        let rules = try JSONDecoder().decode(FocusRules.self, from: data)
        XCTAssertEqual(rules.visibility(for: "app.override", notched: true), .hide)
        XCTAssertEqual(rules.visibility(for: "app.override", notched: false), .show)
        XCTAssertEqual(rules.visibility(for: "app.partial", notched: false), .hide)
        XCTAssertEqual(rules.visibility(for: nil, notched: true), .show)
        XCTAssertEqual(FocusRules.builtIn.visibility(for: "app.unknown", notched: false), .hide)
    }

    private class Preference {
        var value: Bool?
        var writes: [Bool?] = []
    }

    private func withTrial(_ original: Bool?, _ test: (VisibilityTrial, Preference) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preference = Preference()
        preference.value = original
        let trial = VisibilityTrial(journal: directory.appendingPathComponent("test.json"), read: {
            preference.value
        }, write: { value in
            preference.writes.append(value)
            preference.value = value
        })
        try test(trial, preference)
    }
}
