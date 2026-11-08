import Foundation

public enum RiskTier: String, Codable, CaseIterable, Sendable {
    case safe = "Safe"
    case review = "Review"
    case locked = "Locked"
}

public enum Category: String, Codable, CaseIterable, Sendable {
    case temp = "Temp"
    case browserCache = "BrowserCache"
    case appCache = "AppCache"
    case crashData = "CrashData"
    case systemUpdates = "SystemUpdates"
    case trash = "Trash"
    case oldLogs = "OldLogs"
    case oldDownloads = "OldDownloads"
    case nodeModules = "NodeModules"
    case largeFile = "LargeFile"
}

public enum CleanMode: String, Codable, Sendable {
    case trash = "Trash"
    case permanent = "Permanent"
}

public enum CategoryInfo {
    public static func name(_ c: Category) -> String {
        switch c {
        case .temp: return "Temporary files"
        case .browserCache: return "Browser caches"
        case .appCache: return "App & developer caches"
        case .crashData: return "Crash reports & logs"
        case .systemUpdates: return "macOS & Xcode updates"
        case .trash: return "Trash"
        case .oldLogs: return "Old log files"
        case .oldDownloads: return "Old downloads"
        case .nodeModules: return "Unused node_modules"
        case .largeFile: return "Large files"
        }
    }
}

/// One item the scan suggests cleaning: a file, a folder, or the Trash.
public struct Finding: Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedUtc: Date
    /// The item's own last-write time at scan time; the cleaner re-checks it before deleting.
    public let stampUtc: Date
    public let category: Category
    public let tier: RiskTier
    public let reason: String
    /// Delete what is inside the folder but keep the folder itself (used for caches and Trash).
    public let contentsOnly: Bool
    public let label: String?
    public let needsAdmin: Bool

    public init(
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedUtc: Date,
        stampUtc: Date,
        category: Category,
        tier: RiskTier,
        reason: String,
        contentsOnly: Bool = false,
        label: String? = nil,
        needsAdmin: Bool = false
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedUtc = modifiedUtc
        self.stampUtc = stampUtc
        self.category = category
        self.tier = tier
        self.reason = reason
        self.contentsOnly = contentsOnly
        self.label = label
        self.needsAdmin = needsAdmin
    }
}

public struct ScanOptions: Sendable {
    public let roots: [String]
    public let largeFileThreshold: Int64
    public let includeKnownLocations: Bool

    public init(
        roots: [String],
        largeFileThreshold: Int64 = 500 * 1024 * 1024,
        includeKnownLocations: Bool = true
    ) {
        self.roots = roots
        self.largeFileThreshold = largeFileThreshold
        self.includeKnownLocations = includeKnownLocations
    }
}

public struct ScanProgress: Sendable {
    public let filesScanned: Int64
    public let bytesScanned: Int64
    public let foundBytes: Int64
    public let findingCount: Int
    public let deniedFolders: Int
    public let currentFolder: String

    public init(
        filesScanned: Int64,
        bytesScanned: Int64,
        foundBytes: Int64,
        findingCount: Int,
        deniedFolders: Int,
        currentFolder: String
    ) {
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.foundBytes = foundBytes
        self.findingCount = findingCount
        self.deniedFolders = deniedFolders
        self.currentFolder = currentFolder
    }
}

public struct ScanResult: Sendable {
    public let findings: [Finding]
    public let deniedFolders: Int
    public let filesScanned: Int64
    public let bytesScanned: Int64
    public let elapsed: TimeInterval
    public let cancelled: Bool

    public init(
        findings: [Finding] = [],
        deniedFolders: Int = 0,
        filesScanned: Int64 = 0,
        bytesScanned: Int64 = 0,
        elapsed: TimeInterval = 0,
        cancelled: Bool = false
    ) {
        self.findings = findings
        self.deniedFolders = deniedFolders
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.elapsed = elapsed
        self.cancelled = cancelled
    }
}

public struct CleanFailure: Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct CleanProgress: Sendable {
    public let done: Int
    public let total: Int
    public let current: String

    public init(done: Int, total: Int, current: String) {
        self.done = done
        self.total = total
        self.current = current
    }
}

public final class CleanResult: @unchecked Sendable {
    public let mode: CleanMode
    public var itemsCleaned: Int = 0
    /// Bytes actually removed from disk (permanent delete, or Trash emptied).
    public var bytesFreed: Int64 = 0
    /// Bytes moved into the Trash; they only free space once the Trash is emptied.
    public var bytesRecycled: Int64 = 0
    public var failures: [CleanFailure] = []
    /// Paths of items that were cleaned completely.
    public var cleanedPaths: [String] = []
    public var cancelled: Bool = false
    public var logPath: String?

    public init(mode: CleanMode, logPath: String? = nil) {
        self.mode = mode
        self.logPath = logPath
    }
}
