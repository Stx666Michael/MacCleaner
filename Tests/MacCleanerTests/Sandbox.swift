import Foundation
import Darwin
@testable import MacCleanerCore

/// A throwaway directory tree with its own Rules, so tests never touch real user files.
///   System/             protected (System/Temp is an approved per-child temp location)
///   Users/me/           the "current user"; Users/other/ belongs to someone else
///   Users/me/Cache      approved whole-folder cache
public final class Sandbox {
    public let root: String
    public var system: String { PathUtil.combine(root, "System") }
    public var sysTemp: String { PathUtil.combine(system, "Temp") }
    public var me: String { PathUtil.combine(root, "Users/me") }
    public var other: String { PathUtil.combine(root, "Users/other") }
    public var cache: String { PathUtil.combine(me, "Cache") }
    public var downloads: String { PathUtil.combine(me, "Downloads") }
    public var outside: String { PathUtil.combine(root, "Outside") }
    public let rules: Rules

    public init() {
        let tmp = (try? PathUtil.normalize(NSTemporaryDirectory())) ?? "/private/tmp"
        let shortId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        self.root = PathUtil.combine(tmp, "mc-test-\(shortId)")

        let dirs = [
            PathUtil.combine(root, "System/Temp"),
            PathUtil.combine(root, "Users/me/Cache"),
            PathUtil.combine(root, "Users/me/Downloads"),
            PathUtil.combine(root, "Users/other"),
            PathUtil.combine(root, "Outside")
        ]
        for d in dirs {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }

        self.rules = Rules(
            RulesConfig(
                protectedRoots: [PathUtil.combine(root, "System")],
                knownLocations: [
                    KnownLocation(
                        path: PathUtil.combine(root, "System/Temp"),
                        category: .temp,
                        label: "System temp file",
                        perChild: true,
                        minAge: 24 * 3600,
                        needsAdmin: true
                    ),
                    KnownLocation(
                        path: PathUtil.combine(root, "Users/me/Cache"),
                        category: .appCache,
                        label: "Test cache",
                        perChild: false
                    )
                ],
                userProfile: PathUtil.combine(root, "Users/me"),
                downloadsDir: PathUtil.combine(root, "Users/me/Downloads")
            )
        )
    }

    @discardableResult
    public func file(_ path: String, bytes: Int = 10, ageDays: Int = 0) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = Data(count: bytes)
        FileManager.default.createFile(atPath: path, contents: data)
        if ageDays > 0 {
            let past = Date().addingTimeInterval(-Double(ageDays) * 86400.0)
            setMtime(path, date: past)
        }
        return (try? PathUtil.normalize(path)) ?? path
    }

    public func setMtime(_ path: String, date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    @discardableResult
    public func symlink(_ link: String, target: String) -> String {
        let dir = (link as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        return (try? PathUtil.normalize(link)) ?? link
    }

    public static func make(
        _ path: String,
        size: Int64,
        cat: MacCleanerCore.Category = .largeFile,
        tier: RiskTier = .review,
        isDir: Bool = false,
        contentsOnly: Bool = false
    ) -> Finding {
        var st = stat()
        let stamp: Date
        if lstat(path, &st) == 0 {
            stamp = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0)
        } else {
            stamp = Date()
        }
        return Finding(
            path: path,
            isDirectory: isDir,
            size: size,
            modifiedUtc: stamp,
            stampUtc: stamp,
            category: cat,
            tier: tier,
            reason: "test",
            contentsOnly: contentsOnly
        )
    }

    public func newCleaner() -> Cleaner {
        Cleaner(rules, logPath: PathUtil.combine(root, "clean-log.txt"))
    }

    public func dispose() {
        // Remove symlinks first so recursive delete never wanders outside the sandbox.
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    unlink(url.path)
                }
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    deinit {
        dispose()
    }
}
