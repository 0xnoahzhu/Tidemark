import Foundation

/// Private UserDefaults suites for one test, removed together with their files when this is released.
///
/// Tests run inside the app, so `UserDefaults.standard` is the real app's domain; each test writes to suites of its
/// own instead. A suite left behind stays in `~/Library/Preferences` as a `.plist`, one per test and run.
final class TestDefaults {
    private var names: [String] = []

    /// A new, empty suite.
    func make() -> UserDefaults {
        let name = "tidemark-tests-\(UUID().uuidString)"
        names.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// Removes every suite made so far.
    func removeAll() {
        names.forEach(Self.remove)
        names.removeAll()
    }

    deinit { names.forEach(Self.remove) }

    /// Removes the suite `name` and its file.
    static func remove(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: URL.libraryDirectory.appending(path: "Preferences/\(name).plist"))
    }
}
