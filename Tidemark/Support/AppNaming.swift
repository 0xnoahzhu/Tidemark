import Foundation
import Synchronization

/// One name for an app everywhere: Finder's display name of its bundle, without `.app`
/// ("Visual Studio Code", not its executable's or CFBundleName's "Code"; "日历" for Calendar on a Chinese
/// system). Cached, since tables ask for it on every row.
enum AppNaming {
    private static let cache = Mutex<[String: String]>([:])

    static func displayName(forBundlePath rawPath: String) -> String {
        let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        if let hit = cache.withLock({ $0[path] }) { return hit }
        let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var name = FileManager.default.fileExists(atPath: path) ? FileManager.default.displayName(atPath: path) : fallback
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty { name = fallback }
        cache.withLock { $0[path] = name }
        return name
    }
}
