import Foundation

final class AppVisibilityRules {
    private let directory: URL
    private let read: (String) throws -> Bool?
    private let write: (String, Bool?) throws -> Void
    private(set) var prepared: Set<String> = []

    init(directory: URL, read: @escaping (String) throws -> Bool?, write: @escaping (String, Bool?) throws -> Void) {
        self.directory = directory
        self.read = read
        self.write = write
    }

    static func isBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }
    }

    func update(_ desired: Set<String>) throws {
        for id in prepared.subtracting(desired) {
            _ = try trial(for: id).recover()
            prepared.remove(id)
        }
        for id in desired.subtracting(prepared) {
            _ = try trial(for: id).begin(true)
            prepared.insert(id)
        }
    }

    func recover() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let prefix = "app-"
        let suffix = ".json"
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(suffix) {
            let id = String(file.dropFirst(prefix.count).dropLast(suffix.count))
            guard Self.isBundleID(id) else { continue }
            _ = try trial(for: id).recover()
        }
        prepared.removeAll()
    }

    func check(_ id: String) throws {
        guard try read(id) == true else {
            throw ProbeError("An app’s full-screen menu bar setting changed. Rules paused so your change stays in place.")
        }
    }

    private func trial(for id: String) -> VisibilityTrial {
        VisibilityTrial(journal: directory.appendingPathComponent("app-\(id).json"),
                        read: { [read] in try read(id) }, write: { [write] in try write(id, $0) })
    }
}
