import Foundation
import XCTest
@testable import MenuBarProbe

final class BarSettingsTests: XCTestCase {
    func testDefaultsAndAppExceptionRoundTrip() throws {
        var settings = BarSettings()
        XCTAssertEqual(settings.mode(for: nil, notched: true), .show)
        XCTAssertEqual(settings.mode(for: nil, notched: false), .hide)

        settings.enabled = false
        settings.apps = [.init(id: "example.player", name: "Player", modes: .init(notched: .hide, unnotched: .system))]
        let data = try JSONEncoder().encode(settings)
        let saved = try JSONDecoder().decode(BarSettings.self, from: data)
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(saved.mode(for: "example.player", notched: true), .hide)
        XCTAssertEqual(saved.mode(for: "example.player", notched: false), .system)
        XCTAssertNil(saved.mode(for: "example.player", notched: false).visibility)
        XCTAssertEqual(saved.mode(for: "another.app", notched: true), .show)
    }

    func testPlaybackOverridesDisplayDefaultsAndAppExceptionsOnlyWhenEnabled() throws {
        var settings = BarSettings()
        settings.apps = [.init(id: "example.player", name: "Player", modes: .init(notched: .system, unnotched: .show))]
        XCTAssertEqual(settings.mode(for: "example.browser", notched: true, playingMedia: true), .show)

        settings.autoHideDuringPlayback = true
        XCTAssertEqual(settings.mode(for: "example.browser", notched: true, playingMedia: true), .hide)
        XCTAssertEqual(settings.mode(for: "example.player", notched: false, playingMedia: true), .hide)
        XCTAssertEqual(settings.mode(for: "example.player", notched: false, playingMedia: false), .show)
        XCTAssertEqual(settings.mode(for: "example.player", notched: true, playingMedia: false), .system)

        let saved = try JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(saved.autoHideDuringPlayback)
    }

    func testOlderSettingsKeepTheirRulesWithoutEnablingPlaybackOverride() throws {
        let data = Data("""
            {"enabled":false,"displays":{"notched":"system"},"apps":[{"id":"example.player","name":"Player","modes":{"notched":"hide"}}]}
            """.utf8)
        let settings = try JSONDecoder().decode(BarSettings.self, from: data)
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.autoHideDuringPlayback)
        XCTAssertEqual(settings.mode(for: "example.player", notched: true), .hide)
        XCTAssertEqual(settings.mode(for: "example.browser", notched: true), .system)
    }

    func testBlankAppRuleFollowsTheDisplayDefault() {
        var settings = BarSettings()
        settings.apps = [.init(id: "example.player", name: "Player")]
        XCTAssertEqual(settings.mode(for: "example.player", notched: true), .show)
        settings.displays[.notched] = .system
        XCTAssertEqual(settings.mode(for: "example.player", notched: true), .system)
        XCTAssertEqual(settings.mode(for: "example.player", notched: false), .hide)
    }
}
