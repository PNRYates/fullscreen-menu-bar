import Foundation
import XCTest
@testable import MenuBarProbe

final class AppVisibilityRulesTests: XCTestCase {
    func testOnlyDisplayIndependentKeepVisibleExceptionsArePrepared() {
        var settings = BarSettings()
        settings.apps = [
            .init(id: "app.both", name: "Both", modes: .init(notched: .show, unnotched: .show)),
            .init(id: "app.inherited", name: "Inherited", modes: .init(unnotched: .show)),
            .init(id: "app.one", name: "One", modes: .init(notched: .show)),
            .init(id: "app.system", name: "System", modes: .init(notched: .system, unnotched: .show)),
            .init(id: "app.default", name: "Default"),
        ]
        XCTAssertEqual(settings.scopedVisibleExceptions(on: [:]) { _ in true }, ["app.both", "app.inherited"])
        settings.autoHideDuringPlayback = true
        XCTAssertEqual(settings.scopedVisibleExceptions(on: [:]) { $0 == "app.inherited" }, ["app.both"])
        settings.displays.notched = .hide
        XCTAssertEqual(settings.scopedVisibleExceptions(on: [:]) { _ in false }, ["app.both"])
        XCTAssertTrue(settings.scopedVisibleExceptions(on: [:]) { _ in true }.isEmpty)
    }

    func testDisplayDependentRuleUsesCurrentAssignmentAndDoesNotGuess() {
        var settings = BarSettings()
        settings.apps = [.init(id: "app.mixed", name: "Mixed", modes: .init(notched: .show, unnotched: .hide))]
        XCTAssertEqual(settings.displayDependentAppIDs, ["app.mixed"])
        XCTAssertEqual(settings.scopedVisibleExceptions(on: ["app.mixed": .notched]) { _ in false }, ["app.mixed"])
        XCTAssertTrue(settings.scopedVisibleExceptions(on: ["app.mixed": .unnotched]) { _ in false }.isEmpty)
        XCTAssertTrue(settings.scopedVisibleExceptions(on: [:]) { _ in false }.isEmpty)
        settings.autoHideDuringPlayback = true
        XCTAssertTrue(settings.scopedVisibleExceptions(on: ["app.mixed": .notched]) { _ in true }.isEmpty)
        settings.apps[0].modes = .init(notched: .hide, unnotched: .show)
        XCTAssertEqual(settings.scopedVisibleExceptions(on: ["app.mixed": .unnotched]) { _ in false }, ["app.mixed"])
        XCTAssertTrue(settings.scopedVisibleExceptions(on: ["app.mixed": .notched]) { _ in false }.isEmpty)
    }

    func testOwnershipRejectsMissingDisplayAndMultipleSpaces() {
        let id = "app.mixed"
        XCTAssertEqual(FocusedSpaceReader.unambiguousDisplays(in: [id: [.unnotched]]), [id: .unnotched])
        XCTAssertEqual(FocusedSpaceReader.unambiguousDisplays(in: [id: [.notched]]), [id: .notched])
        XCTAssertTrue(FocusedSpaceReader.unambiguousDisplays(in: [id: [nil]]).isEmpty)
        XCTAssertTrue(FocusedSpaceReader.unambiguousDisplays(in: [id: [.notched, nil]]).isEmpty)
        XCTAssertTrue(FocusedSpaceReader.unambiguousDisplays(in: [id: [.notched, .unnotched]]).isEmpty)
    }

    func testPrepareAndRecoveryOnlyChangeExceptionDomains() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        var values = ["app.other": false, "app.external": false, "app.already": true]
        var writes: [String] = []
        func makeRules() -> AppVisibilityRules {
            AppVisibilityRules(directory: dir, read: { values[$0] }, write: {
                writes.append($0)
                values[$0] = $1
            })
        }
        let rules = makeRules()
        try rules.update(["app.changed"])
        try rules.update(["app.changed"])
        try rules.check("app.changed")
        XCTAssertEqual(writes, ["app.changed"])
        XCTAssertEqual(values["app.changed"], true)
        XCTAssertEqual(values["app.other"], false)
        try rules.update([])
        XCTAssertNil(values["app.changed"])
        XCTAssertTrue(rules.prepared.isEmpty)
        try rules.update(["app.already", "app.external"])
        values["app.external"] = false
        XCTAssertThrowsError(try rules.check("app.external"))
        try makeRules().recover()
        XCTAssertEqual(values, ["app.other": false, "app.external": false, "app.already": true])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
