import Foundation
import AppKit

public struct VolumeInfo: Sendable, Identifiable, Equatable {
    public var id: String { root }
    public let root: String
    public let name: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isSystemVolume: Bool

    public init(root: String, name: String, totalBytes: Int64, freeBytes: Int64, isSystemVolume: Bool) {
        self.root = root
        self.name = name
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isSystemVolume = isSystemVolume
    }
}

public enum MacOSIntegration {
    /// Returns true if the current process has Full Disk Access (or root privileges).
    /// Probes TCC-protected directories in the user's home Library and `/Library/Application Support/com.apple.TCC`.
    public static func hasFullDiskAccess() -> Bool {
        if geteuid() == 0 {
            return true
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let library = PathUtil.combine(home, "Library")
        let tccCandidates = [
            PathUtil.combine(library, "Safari"),
            PathUtil.combine(library, "Mail"),
            PathUtil.combine(library, "Messages"),
            PathUtil.combine(library, "Cookies"),
            PathUtil.combine(library, "Suggestions"),
            PathUtil.combine(library, "IdentityServices"),
            PathUtil.combine(library, "HomeKit"),
            PathUtil.combine(library, "Sharing"),
            PathUtil.combine(library, "Metadata/CoreSpotlight"),
            PathUtil.combine(library, "Caches/CloudKit"),
            PathUtil.combine(library, "Caches/com.apple.Safari"),
            "/Library/Application Support/com.apple.TCC"
        ]

        var sawProtectedDir = false
        for path in tccCandidates {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }
            sawProtectedDir = true
            if let dp = opendir(path) {
                closedir(dp)
                return true
            }
        }
        return !sawProtectedDir
    }

    /// Returns the path to the current user's Trash folder (`~/.Trash`).
    public static var userTrashPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (try? PathUtil.normalize(PathUtil.combine(home, ".Trash"))) ?? PathUtil.combine(home, ".Trash")
    }

    /// Queries the size and item count of the user's Trash folder.
    public static func queryTrash(isCancelled: () -> Bool = { false }) -> (size: Int64, items: Int64)? {
        let trash = userTrashPath
        guard let entries = try? FsUtil.enumerate(trash), !entries.isEmpty else {
            return nil
        }
        var totalBytes: Int64 = 0
        var itemCount: Int64 = 0
        for e in entries {
            if e.name == ".DS_Store" { continue }
            itemCount += 1
            let childPath = PathUtil.combine(trash, e.name)
            if e.isSymlink {
                continue
            } else if e.isDirectory {
                let m = FsUtil.measure(childPath, isCancelled: isCancelled)
                totalBytes += m.bytes
            } else {
                totalBytes += e.length
            }
        }
        guard totalBytes > 0 && itemCount > 0 else { return nil }
        return (totalBytes, itemCount)
    }

    /// Empties `~/.Trash` safely without following symlinks.
    public static func emptyTrash() -> String? {
        let trash = userTrashPath
        guard let entries = try? FsUtil.enumerate(trash) else {
            return nil
        }
        var firstError: String?
        for e in entries {
            let full = PathUtil.combine(trash, e.name)
            if e.isSymlink {
                unlink(full)
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: full)
            } catch {
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }
        return firstError
    }

    /// Moves a single path to the macOS Trash using FileManager.trashItem.
    public static func moveToTrash(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Lists mounted local volumes suitable for scanning (root `/` plus external/secondary volumes in `/Volumes`).
    public static func listVolumes() -> [VolumeInfo] {
        var result: [VolumeInfo] = []
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey
        ]

        // Always include the root boot volume `/`
        let rootURL = URL(fileURLWithPath: "/")
        if let vals = try? rootURL.resourceValues(forKeys: keys) {
            let name = vals.volumeName ?? "Macintosh HD"
            let total = Int64(vals.volumeTotalCapacity ?? 0)
            let free = vals.volumeAvailableCapacityForImportantUsage ?? Int64(vals.volumeAvailableCapacity ?? 0)
            result.append(VolumeInfo(root: "/", name: name, totalBytes: total, freeBytes: max(0, free), isSystemVolume: true))
        }

        if let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) {
            for url in urls {
                let path = url.path
                if path == "/" || path.hasPrefix("/System/Volumes") || path.hasPrefix("/private/") || path.hasPrefix("/dev") {
                    continue
                }
                guard let vals = try? url.resourceValues(forKeys: keys) else { continue }
                if vals.volumeIsLocal == false { continue }
                let name = vals.volumeName ?? url.lastPathComponent
                let total = Int64(vals.volumeTotalCapacity ?? 0)
                let free = vals.volumeAvailableCapacityForImportantUsage ?? Int64(vals.volumeAvailableCapacity ?? 0)
                if total <= 0 { continue }
                result.append(VolumeInfo(root: path, name: name, totalBytes: total, freeBytes: max(0, free), isSystemVolume: false))
            }
        }
        return result
    }

    /// Opens Finder and selects the given file or opens the directory.
    public static func revealInFinder(_ path: String, selectFile: Bool = true) {
        let url = URL(fileURLWithPath: path)
        if selectFile {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a file with its default application (e.g. log file in Console / TextEdit).
    public static func openFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
}
