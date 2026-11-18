import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
struct MediaPlaybackReader {
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    private var nextSample: TimeInterval = 0
    private var playingApps: Set<pid_t> = []

    mutating func isPlaying(in ownerPID: pid_t, at time: TimeInterval) -> Bool {
        if time >= nextSample {
            nextSample = time + 0.5
            playingApps = Self.sample()
        }
        return playingApps.contains(ownerPID)
    }

    private static func sample() -> Set<pid_t> {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let assertions = raw?.takeRetainedValue() as? [pid_t: [[String: Any]]] else { return [] }
        return playbackOwners(in: assertions) { responsiblePID?($0) ?? $0 }
    }

    // These assertions identify the playing app, not the window or tab presenting the media.
    nonisolated static func playbackOwners(in assertions: [pid_t: [[String: Any]]], responsibleFor: (pid_t) -> pid_t) -> Set<pid_t> {
        var owners: Set<pid_t> = []
        for (pid, entries) in assertions {
            for entry in entries {
                guard entry["AssertLevel"] as? Int == Int(kIOPMAssertionLevelOn),
                      let name = (entry["AssertName"] as? String)?.lowercased(),
                      let type = entry["AssertType"] as? String else { continue }
                let attributedPID = entry["AssertionOnBehalfOfPID"] as? pid_t
                let client: pid_t
                switch type {
                case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion":
                    guard name.contains("video") || name.contains("playback") || name.contains("avplayer") else { continue }
                    client = attributedPID ?? pid
                case "PreventUserIdleSystemSleep":
                    guard entry["_IsRunningboardd"] as? Bool == true,
                          name.hasSuffix(":webkit media playback"), let attributedPID else { continue }
                    client = attributedPID
                default:
                    continue
                }
                guard client > 0 else { continue }
                owners.insert(client)
                let responsible = responsibleFor(client)
                if responsible > 0 { owners.insert(responsible) }
            }
        }
        return owners
    }

    private static let responsiblePID: ResponsiblePID? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()
}
