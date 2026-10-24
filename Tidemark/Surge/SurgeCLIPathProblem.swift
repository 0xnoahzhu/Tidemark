import Foundation
import System

/// Why a configured surge-cli path cannot be launched, for Settings › Surge.
///
/// Checked with `FilePath.stat()` (System, macOS 27), whose typed `Errno` tells a missing file apart from a
/// folder, a non-executable file or a path that cannot be read. Symbolic links are followed, so
/// `/usr/local/bin/surge-cli` is checked as the app's executable it points to.
enum SurgeCLIPathProblem: Error, Hashable, Sendable {
    case missing
    case notAFile
    case notExecutable
    case inaccessible(Errno)

    /// The problem with the executable at `path`, or nil when surge-cli can be launched from there.
    init?(checking path: String) {
        guard !path.isEmpty else {
            self = .missing
            return
        }
        let status: Stat
        do {
            status = try FilePath(path).stat()
        } catch .noSuchFileOrDirectory, .notDirectory {
            self = .missing
            return
        } catch {
            self = .inaccessible(error)
            return
        }
        guard status.type == .regular else {
            self = .notAFile
            return
        }
        // The permission bits alone ignore ACLs and the effective user; `access(X_OK)` decides.
        guard FileManager.default.isExecutableFile(atPath: path) else {
            self = .notExecutable
            return
        }
        return nil
    }

    /// English description; the `SurgeCLI` string table translates it (`trf` with the error text for
    /// `.inaccessible`).
    var message: String {
        switch self {
        case .missing: "No file at this path."
        case .notAFile: "This path is a folder, not the surge-cli executable."
        case .notExecutable: "This file is not executable."
        case .inaccessible: "This path cannot be read: %@"
        }
    }
}
