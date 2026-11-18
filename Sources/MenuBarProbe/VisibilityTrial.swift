import Foundation

struct VisibilityTrial {
    enum Outcome: Equatable {
        case noChange, restored, changedElsewhere
    }

    struct Snapshot: Codable, Equatable {
        let original: Bool?
        let applied: Bool
        var previousApplied: Bool? = nil
    }

    let journal: URL
    let read: () throws -> Bool?
    let write: (Bool?) throws -> Void

    func checkForRecoveryRecord() throws {
        guard !FileManager.default.fileExists(atPath: journal.path) else {
            throw ProbeError("An earlier run has a recovery record. Run `MenuBarProbe recover` first.")
        }
    }

    func begin(_ visible: Bool) throws -> Bool {
        try checkForRecoveryRecord()
        let original = try read()
        guard original != visible else { return false }
        let snapshot = Snapshot(original: original, applied: visible)
        try JSONEncoder().encode(snapshot).write(to: journal, options: .atomic)
        try write(visible)
        return true
    }

    func run(_ visible: Bool, observe: () throws -> Void) throws -> Outcome {
        try withCleanup {
            if try begin(visible) { try observe() }
        }
    }

    func withCleanup(_ perform: () throws -> Void) throws -> Outcome {
        try checkForRecoveryRecord()
        do {
            try perform()
        } catch {
            let runError = error
            do { _ = try recover() } catch {
                throw ProbeError("Run failed: \(runError). Restore also failed: \(error). Run `MenuBarProbe recover` to retry.")
            }
            throw runError
        }
        return try recover() ?? .noChange
    }

    func switchTo(_ visible: Bool) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: journal.path) else {
            _ = try begin(visible)
            return .noChange
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: journal))
        guard try read() == snapshot.applied else { return .changedElsewhere }
        guard visible != snapshot.applied else { return .noChange }
        if snapshot.original == visible { return try recover() ?? .noChange }
        try JSONEncoder().encode(Snapshot(original: snapshot.original, applied: visible,
                                          previousApplied: snapshot.applied)).write(to: journal, options: .atomic)
        try write(visible)
        try JSONEncoder().encode(Snapshot(original: snapshot.original, applied: visible)).write(to: journal, options: .atomic)
        return .noChange
    }

    func recover() throws -> Outcome? {
        guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: journal))
        let current = try read()
        let outcome: Outcome
        if current == snapshot.applied || (snapshot.previousApplied != nil && current == snapshot.previousApplied) {
            try write(snapshot.original)
            outcome = .restored
        } else {
            outcome = current == snapshot.original ? .noChange : .changedElsewhere
        }
        try FileManager.default.removeItem(at: journal)
        return outcome
    }
}

struct ProbeError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
