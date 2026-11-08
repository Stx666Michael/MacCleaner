import Foundation
import Darwin

public struct FsEntry: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let length: Int64
    public let lastWriteUtc: Date
    public let isSymlink: Bool
    public let isSystemImmutable: Bool
    public let isCloudOnly: Bool

    public init(
        name: String,
        isDirectory: Bool,
        length: Int64,
        lastWriteUtc: Date,
        isSymlink: Bool = false,
        isSystemImmutable: Bool = false,
        isCloudOnly: Bool = false
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.length = length
        self.lastWriteUtc = lastWriteUtc
        self.isSymlink = isSymlink
        self.isSystemImmutable = isSystemImmutable
        self.isCloudOnly = isCloudOnly
    }
}

public struct Measurement: Sendable {
    public let bytes: Int64
    public let newestUtc: Date
    public let files: Int64

    public init(bytes: Int64, newestUtc: Date, files: Int64) {
        self.bytes = bytes
        self.newestUtc = newestUtc
        self.files = files
    }
}

public enum FsError: Error {
    case accessDenied(String)
    case ioError(String)
}

public enum FsUtil {
    /// Lists one folder using POSIX opendir/readdir + lstat for speed and accuracy.
    /// Never follows symlinks and flags cloud-only (evicted iCloud) files.
    /// Throws `FsError.accessDenied` on `EACCES` / `EPERM` or `FsError.ioError` on other errors.
    public static func enumerate(_ dir: String) throws -> [FsEntry] {
        guard let dp = opendir(dir) else {
            let err = errno
            if err == EACCES || err == EPERM {
                throw FsError.accessDenied(dir)
            }
            throw FsError.ioError("Cannot open directory \(dir): errno \(err)")
        }
        defer { closedir(dp) }

        var results: [FsEntry] = []
        let checkCloud = dir.contains("/Mobile Documents/") || dir.contains("/CloudStorage/")

        while let entryPtr = readdir(dp) {
            let dName = withUnsafePointer(to: entryPtr.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entryPtr.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if dName == "." || dName == ".." { continue }

            let fullPath = PathUtil.combine(dir, dName)
            var st = stat()
            if lstat(fullPath, &st) != 0 {
                continue
            }

            let mode = st.st_mode & S_IFMT
            let isSymlink = (mode == S_IFLNK)
            let isDir = (mode == S_IFDIR)
            let isReg = (mode == S_IFREG)

            if !isSymlink && !isDir && !isReg {
                // Skip sockets, FIFOs, block/char devices
                continue
            }

            let mtimeSec = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
            let modDate = Date(timeIntervalSince1970: mtimeSec)
            let length: Int64 = isDir || isSymlink ? 0 : Int64(st.st_size)

            // SF_IMMUTABLE (0x00020000) or SF_RESTRICTED (0x00080000) indicate macOS system-protected files
            let sysImmutable = (st.st_flags & UInt32(SF_IMMUTABLE | 0x00080000)) != 0

            // Detect iCloud evicted placeholder files (either `.icloud` wrapper or dataless attribute SF_DATALESS 0x40000000)
            let isDataless = (st.st_flags & 0x40000000) != 0
            let isICloudPlaceholder = checkCloud && dName.hasPrefix(".") && dName.hasSuffix(".icloud")
            let isCloudOnly = isDataless || isICloudPlaceholder

            results.append(
                FsEntry(
                    name: dName,
                    isDirectory: isDir,
                    length: length,
                    lastWriteUtc: modDate,
                    isSymlink: isSymlink,
                    isSystemImmutable: sysImmutable,
                    isCloudOnly: isCloudOnly
                )
            )
        }
        return results
    }

    /// Total size of a folder tree. Never follows symlinks and ignores cloud-only placeholders.
    /// Unreadable folders are skipped and counted through `onDenied`.
    /// Optional `onDirectory` reports `(dirPath, filesInDir, bytesInDir)` as each directory is scanned.
    public static func measure(
        _ root: String,
        isCancelled: () -> Bool = { Task.isCancelled },
        onDenied: (() -> Void)? = nil,
        onDirectory: ((String, Int64, Int64) -> Void)? = nil
    ) -> Measurement {
        var bytes: Int64 = 0
        var files: Int64 = 0
        var newest: Date = .distantPast
        var stack: [String] = [root]

        while let dir = stack.popLast() {
            if isCancelled() { break }
            let entries: [FsEntry]
            do {
                entries = try enumerate(dir)
            } catch FsError.accessDenied {
                onDenied?()
                continue
            } catch {
                continue
            }

            var dirBytes: Int64 = 0
            var dirFiles: Int64 = 0

            for e in entries {
                if e.isSymlink || e.isCloudOnly { continue }
                if e.isDirectory {
                    stack.append(PathUtil.combine(dir, e.name))
                    continue
                }
                dirBytes += e.length
                dirFiles += 1
                if e.lastWriteUtc > newest {
                    newest = e.lastWriteUtc
                }
            }

            bytes += dirBytes
            files += dirFiles
            onDirectory?(dir, dirFiles, dirBytes)
        }
        return Measurement(bytes: bytes, newestUtc: newest, files: files)
    }
}
