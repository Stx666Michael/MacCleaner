import Foundation
import Darwin

/// The only code that deletes anything. Every item is re-validated right before it is touched, so a
/// stale or tampered list can never remove a protected path, follow a link out of the scanned area,
/// or delete a file that changed after the scan.
public final class Cleaner: Sendable {
    private let _rules: Rules
    private let _logPath: String

    public init(_ rules: Rules, logPath: String? = nil) {
        self._rules = rules
        self._logPath = logPath ?? Self.defaultLogPath
    }

    public static var defaultLogPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return PathUtil.combine(home, "Library/Logs/MacCleaner/clean-log.txt")
    }

    public func clean(
        _ items: [Finding],
        mode: CleanMode,
        progress: ((CleanProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> CleanResult {
        let result = CleanResult(mode: mode, logPath: _logPath)
        var logLines: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        logLines.append("=== \(formatter.string(from: Date())) clean started, mode=\(mode.rawValue), items=\(items.count)")

        for (i, f) in items.enumerated() {
            if isCancelled() {
                result.cancelled = true
                break
            }
            progress?(CleanProgress(done: i, total: items.count, current: f.label ?? f.path))
            let outcome = cleanOne(f, mode: mode, result: result, isCancelled: isCancelled)
            if let outcome {
                result.failures.append(CleanFailure(path: f.path, reason: outcome))
                logLines.append("SKIP   \(f.path) :: \(outcome)")
            } else {
                result.itemsCleaned += 1
                result.cleanedPaths.append(f.path)
                let verb = (mode == .permanent || f.category == .trash) ? "DELETE" : "TRASH"
                logLines.append("\(verb) \(f.path) (\(f.size) bytes)")
            }
        }

        progress?(CleanProgress(done: items.count, total: items.count, current: ""))
        logLines.append("=== done: cleaned=\(result.itemsCleaned), failed=\(result.failures.count), freed=\(result.bytesFreed), recycled=\(result.bytesRecycled)")

        let logContent = logLines.joined(separator: "\n") + "\n"
        do {
            let logDir = (_logPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: _logPath),
               let handle = FileHandle(forWritingAtPath: _logPath) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if let data = logContent.data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
            } else {
                try logContent.write(toFile: _logPath, atomically: true, encoding: .utf8)
            }
        } catch {
            // logging must never break a clean
        }

        return result
    }

    /// Returns nil on success, otherwise the reason the item was not (fully) cleaned.
    private func cleanOne(
        _ f: Finding,
        mode: CleanMode,
        result: CleanResult,
        isCancelled: () -> Bool
    ) -> String? {
        if f.tier == .locked {
            return "Protected item"
        }

        if f.category == .trash {
            return emptyTrashFinding(f, result: result)
        }

        let p: String
        do {
            p = try PathUtil.normalize(f.path)
        } catch {
            return "Unsupported or unsafe path"
        }

        // 1. Policy: is this path allowed at all?
        if f.contentsOnly {
            if !_rules.isKnownLocationRoot(p) {
                return "Not an approved cache folder"
            }
        } else {
            if let lockReason = _rules.getDeleteBlockReason(p) {
                return lockReason
            }
        }

        // 2. The path must be what it claims: no symlink anywhere in it.
        if PathUtil.hasSymlinkComponent(p) {
            // Distinguish between non-existent vs symlink
            var stCheck = stat()
            if lstat(p, &stCheck) != 0 {
                // Check if an ancestor is a symlink
                return "Path goes through a link"
            }
            return "Path goes through a link"
        }

        var st = stat()
        if lstat(p, &st) != 0 {
            return f.isDirectory ? "Folder no longer exists" : "File no longer exists"
        }

        guard let finalPath = PathUtil.resolveFinal(p) else {
            return f.isDirectory ? "Folder no longer exists" : "File no longer exists"
        }
        if finalPath.caseInsensitiveCompare(p) != .orderedSame {
            return "Path goes through a link"
        }
        if !f.contentsOnly, let finalLock = _rules.getLockReason(finalPath) {
            return finalLock
        }

        // 3. It must still be the thing we scanned.
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            return "Is a link or cloud file"
        }
        let isDataless = (st.st_flags & 0x40000000) != 0
        if isDataless {
            return "Is a link or cloud file"
        }
        let isSysImmutable = (st.st_flags & UInt32(SF_IMMUTABLE | 0x00080000)) != 0
        if isSysImmutable {
            return "macOS system file"
        }

        let diskModUtc = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0)
        if !f.isDirectory {
            if fileType != S_IFREG {
                return "Not a regular file"
            }
            let diskSize = Int64(st.st_size)
            if diskSize != f.size || !Self.sameTime(diskModUtc, f.stampUtc) {
                return "Changed since the scan"
            }
        } else {
            if fileType != S_IFDIR {
                return "Not a directory"
            }
            if !f.contentsOnly && !Self.sameTime(diskModUtc, f.stampUtc) {
                return "Folder changed since the scan"
            }
        }

        // 4. Do it.
        let before: Int64 = f.isDirectory ? FsUtil.measure(p, isCancelled: isCancelled).bytes : f.size
        var errorMsg: String?

        if mode == .permanent {
            if f.isDirectory {
                Self.deleteTree(p, deleteSelf: !f.contentsOnly, error: &errorMsg, isCancelled: isCancelled)
            } else {
                Self.deleteFile(p, error: &errorMsg)
            }
        } else {
            let targets = f.contentsOnly ? Self.childPaths(p, error: &errorMsg) : [p]
            for target in targets {
                if isCancelled() { break }
                if let err = MacOSIntegration.moveToTrash(target) {
                    if errorMsg == nil { errorMsg = err }
                }
            }
        }

        var after: Int64 = 0
        var afterStat = stat()
        let stillExists = (lstat(p, &afterStat) == 0)
        if f.isDirectory {
            if stillExists {
                after = FsUtil.measure(p, isCancelled: isCancelled).bytes
            }
        } else if stillExists {
            after = f.size
        }

        let removed = max(0, before - after)
        if mode == .permanent {
            result.bytesFreed += removed
        } else {
            result.bytesRecycled += removed
        }

        let leftovers = f.contentsOnly ? (after > 0) : stillExists
        if !leftovers {
            return nil
        }
        let why = errorMsg ?? "In use or access denied"
        return removed > 0 ? "Partly cleaned (\(Format.size(after)) left): \(why)" : why
    }

    private func emptyTrashFinding(_ f: Finding, result: CleanResult) -> String? {
        if let err = MacOSIntegration.emptyTrash() {
            return "macOS could not empty the Trash: \(err)"
        }
        result.bytesFreed += f.size
        return nil
    }

    private static func sameTime(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 2.0
    }

    private static func childPaths(_ dir: String, error: inout String?) -> [String] {
        var list: [String] = []
        do {
            let entries = try FsUtil.enumerate(dir)
            for e in entries {
                let full = PathUtil.combine(dir, e.name)
                if e.isSymlink {
                    removeLink(full)
                    continue
                }
                list.append(full)
            }
        } catch let err {
            if error == nil { error = err.localizedDescription }
        }
        return list
    }

    private static func deleteFile(_ path: String, error: inout String?) {
        var st = stat()
        if lstat(path, &st) == 0 {
            // Clear user immutable flag or read-only mode if set on user file
            if (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 {
                chflags(path, st.st_flags & ~UInt32(UF_IMMUTABLE))
            }
            if (st.st_mode & S_IWUSR) == 0 {
                chmod(path, st.st_mode | S_IWUSR)
            }
        }
        if unlink(path) != 0 {
            let code = errno
            if error == nil {
                error = String(cString: strerror(code))
            }
        }
    }

    /// Removes a symlink itself without touching what it points to.
    private static func removeLink(_ path: String) {
        _ = unlink(path)
    }

    private static func deleteTree(
        _ dir: String,
        deleteSelf: Bool,
        error: inout String?,
        isCancelled: () -> Bool
    ) {
        let children: [FsEntry]
        do {
            children = try FsUtil.enumerate(dir)
        } catch let err {
            if error == nil { error = err.localizedDescription }
            return
        }

        for c in children {
            if isCancelled() { return }
            let full = PathUtil.combine(dir, c.name)
            if c.isSymlink {
                removeLink(full)
                continue
            }
            if c.isDirectory {
                deleteTree(full, deleteSelf: true, error: &error, isCancelled: isCancelled)
            } else {
                deleteFile(full, error: &error)
            }
        }

        if !deleteSelf { return }
        var st = stat()
        if lstat(dir, &st) == 0 && (st.st_mode & S_IWUSR) == 0 {
            chmod(dir, st.st_mode | S_IWUSR)
        }
        if rmdir(dir) != 0 {
            let code = errno
            if error == nil {
                error = String(cString: strerror(code))
            }
        }
    }
}
