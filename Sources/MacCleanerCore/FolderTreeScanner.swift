import Foundation

public struct TreeProgress: Sendable {
    public let files: Int64
    public let bytes: Int64
    public let deniedFolders: Int
    public let currentFolder: String

    public init(files: Int64, bytes: Int64, deniedFolders: Int, currentFolder: String) {
        self.files = files
        self.bytes = bytes
        self.deniedFolders = deniedFolders
        self.currentFolder = currentFolder
    }
}

public struct FolderTreeResult: Sendable {
    public let root: FolderNode
    public let files: Int64
    public let bytes: Int64
    public let deniedFolders: Int
    public let elapsed: TimeInterval
    public let cancelled: Bool

    public init(
        root: FolderNode,
        files: Int64,
        bytes: Int64,
        deniedFolders: Int,
        elapsed: TimeInterval,
        cancelled: Bool
    ) {
        self.root = root
        self.files = files
        self.bytes = bytes
        self.deniedFolders = deniedFolders
        self.elapsed = elapsed
        self.cancelled = cancelled
    }
}

public enum FolderTreeError: Error, LocalizedError {
    case directoryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let p): return "Folder not found: \(p)"
        }
    }
}

/// Maps how much space every folder under a root uses. Read-only. Never follows symlinks
/// and ignores cloud-only placeholders (they use no local space).
public final class FolderTreeScanner: Sendable {
    public init() {}

    public func scanAsync(
        _ root: String,
        progress: (@Sendable (TreeProgress) -> Void)? = nil
    ) async throws -> FolderTreeResult {
        let path = try PathUtil.normalize(root)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw FolderTreeError.directoryNotFound(path)
        }

        let run = TreeRun(rootPath: path)
        if Task.isCancelled {
            run.cancel()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            run.execute()
        }

        while !run.isFinished {
            if Task.isCancelled {
                run.cancel()
                break
            }
            progress?(run.snapshot())
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if Task.isCancelled {
            run.cancel()
        }
        while !run.isFinished {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        progress?(run.snapshot())
        return run.toResult()
    }
}

private final class TreeRun: @unchecked Sendable {
    private let _root: FolderNode
    private let _rootPath: String
    private let _lock = NSLock()
    private let _startTime = Date()

    private var _files: Int64 = 0
    private var _bytes: Int64 = 0
    private var _denied: Int = 0
    private var _current: String = ""
    private var _cancelled: Bool = false
    private var _finished: Bool = false

    init(rootPath: String) {
        self._rootPath = rootPath
        self._root = FolderNode(name: rootPath, parent: nil)
    }

    func cancel() {
        _lock.lock()
        _cancelled = true
        _lock.unlock()
    }

    var isCancelled: Bool {
        _lock.lock()
        defer { _lock.unlock() }
        return _cancelled
    }

    var isFinished: Bool {
        _lock.lock()
        defer { _lock.unlock() }
        return _finished
    }

    private func markFinished() {
        _lock.lock()
        _finished = true
        _lock.unlock()
    }

    func snapshot() -> TreeProgress {
        _lock.lock()
        defer { _lock.unlock() }
        return TreeProgress(
            files: _files,
            bytes: _bytes,
            deniedFolders: _denied,
            currentFolder: _current
        )
    }

    func toResult() -> FolderTreeResult {
        _lock.lock()
        defer { _lock.unlock() }
        return FolderTreeResult(
            root: _root,
            files: _files,
            bytes: _bytes,
            deniedFolders: _denied,
            elapsed: Date().timeIntervalSince(_startTime),
            cancelled: _cancelled
        )
    }

    func execute() {
        defer { markFinished() }
        if isCancelled { return }
        walk()
        if isCancelled { return }
        Self.finish(_root)
    }

    private func walk() {
        let queueLock = NSCondition()
        var queue: [(FolderNode, String)] = [(_root, _rootPath)]
        var pending = 1
        let workerCount = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount * 2))

        func enqueue(_ node: FolderNode, _ path: String) {
            queueLock.lock()
            pending += 1
            queue.append((node, path))
            queueLock.signal()
            queueLock.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while true {
                queueLock.lock()
                while queue.isEmpty && pending > 0 && !isCancelled {
                    queueLock.wait()
                }
                if isCancelled || (queue.isEmpty && pending == 0) {
                    queueLock.unlock()
                    break
                }
                let (node, path) = queue.removeFirst()
                queueLock.unlock()

                processDir(node: node, path: path, enqueue: enqueue)

                queueLock.lock()
                pending -= 1
                if pending == 0 || isCancelled {
                    queueLock.broadcast()
                }
                queueLock.unlock()
            }
        }
    }

    private func processDir(node: FolderNode, path: String, enqueue: (FolderNode, String) -> Void) {
        if isCancelled { return }
        _lock.lock()
        _current = path
        _lock.unlock()

        let entries: [FsEntry]
        do {
            entries = try FsUtil.enumerate(path)
        } catch FsError.accessDenied {
            node.denied = true
            _lock.lock()
            _denied += 1
            _lock.unlock()
            return
        } catch {
            node.denied = true
            return
        }

        var files: [FileEntry] = []
        var size: Int64 = 0

        for e in entries {
            if e.isSymlink || e.isCloudOnly { continue }
            if e.isDirectory {
                let lower = e.name.lowercased()
                if path == "/" && (lower == "dev" || lower == "volumes" || lower == "net" || lower == "home") {
                    continue
                }
                let childPath = PathUtil.combine(path, e.name)
                if childPath.caseInsensitiveCompare("/System/Volumes") == .orderedSame {
                    continue
                }
                let child = FolderNode(name: e.name, parent: node)
                node.children.append(child)
                enqueue(child, childPath)
            } else {
                size += e.length
                files.append(FileEntry(name: e.name, size: e.length, modifiedUtc: e.lastWriteUtc))
            }
        }

        files.sort { $0.size > $1.size }
        node.ownFilesSize = size
        node.ownFileCount = files.count

        if files.count > FolderNode.maxFilesKept {
            let rest = files[FolderNode.maxFilesKept...]
            node.otherFileCount = rest.count
            node.otherFilesSize = rest.reduce(0) { $0 + $1.size }
            files.removeSubrange(FolderNode.maxFilesKept...)
        }
        node.files = files

        _lock.lock()
        _files += Int64(node.ownFileCount)
        _bytes += size
        _lock.unlock()
    }

    /// Totals each folder from the bottom up (iteratively, so very deep trees cannot overflow the stack).
    private static func finish(_ root: FolderNode) {
        var order: [FolderNode] = []
        var stack: [FolderNode] = [root]
        while let n = stack.popLast() {
            order.append(n)
            for c in n.children {
                stack.append(c)
            }
        }
        for n in order.reversed() {
            var size = n.OwnFilesSizeCompat
            var files = Int64(n.ownFileCount)
            for c in n.children {
                size += c.size
                files += c.fileCount
            }
            n.size = size
            n.fileCount = files
            n.children.sort { $0.size > $1.size }
        }
    }
}

private extension FolderNode {
    var OwnFilesSizeCompat: Int64 { ownFilesSize }
}
