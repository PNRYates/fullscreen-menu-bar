import XCTest
@testable import MenuBarProbe

final class MediaPlaybackReaderTests: XCTestCase {
    func testOnlyActiveVideoDisplayLocksIdentifyTheirOwningApp() {
        let video: [String: Any] = ["AssertType": "PreventUserIdleDisplaySleep",
                                   "AssertLevel": 255, "AssertName": "Video Wake Lock"]
        let assertions = [
            pid_t(10): [video],
            pid_t(20): [video.merging(["AssertionOnBehalfOfPID": NSNumber(value: 21)]) { _, new in new }],
            pid_t(30): [video.merging(["AssertLevel": 0]) { _, new in new }],
            pid_t(40): [video.merging(["AssertType": "PreventUserIdleSystemSleep"]) { _, new in new }],
            pid_t(50): [video.merging(["AssertName": "Screen Wake Lock"]) { _, new in new }],
        ]
        let owners = MediaPlaybackReader.playbackOwners(in: assertions) { $0 == 21 ? 22 : $0 }
        XCTAssertEqual(owners, [10, 21, 22])
    }

    func testRecognisesChromiumAndAttributesWebKitPlaybackToSafari() {
        let webKit: [String: Any] = ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255,
                                   "AssertName": "app<application.com.apple.Safari>:WebKit Media Playback",
                                   "_IsRunningboardd": NSNumber(value: true), "AssertionOnBehalfOfPID": NSNumber(value: 200)]
        let chromium: [String: Any] = ["AssertType": "NoDisplaySleepAssertion", "AssertLevel": 255,
                                     "AssertName": "Video Wake Lock"]
        let assertions: [pid_t: [[String: Any]]] = [455: [webKit, webKit.filter { $0.key != "AssertionOnBehalfOfPID" }],
                                                   300: [chromium]]
        XCTAssertEqual(MediaPlaybackReader.playbackOwners(in: assertions) { $0 }, [200, 300])
    }
}
