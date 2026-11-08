import Foundation

public struct FileEntry: Equatable, Sendable {
    public let name: String
    public let size: Int64
    public let modifiedUtc: Date

    public init(name: String, size: Int64, modifiedUtc: Date) {
        self.name = name
        self.size = size
        self.modifiedUtc = modifiedUtc
    }
}

/// One folder in a scanned disk tree, with the total size of everything below it.
/// Only the largest `maxFilesKept` files of each folder are kept individually; the rest are
/// summed up, so scanning a whole drive stays light on memory.
public final class FolderNode: @unchecked Sendable {
    public static let maxFilesKept: Int = 50

    public let name: String
    public weak var parent: FolderNode?

    /// Sub-folders, largest first (sorted once the scan has finished).
    public var children: [FolderNode] = []

    /// The largest files directly inside this folder, largest first.
    public var files: [FileEntry] = []

    /// Bytes of files directly inside this folder (kept and not kept).
    public var ownFilesSize: Int64 = 0
    public var ownFileCount: Int = 0

    /// Files directly inside this folder that are not listed in `files`.
    public var otherFilesSize: Int64 = 0
    public var otherFileCount: Int = 0

    /// Total bytes in this folder and everything below it.
    public var size: Int64 = 0
    public var fileCount: Int64 = 0

    /// The folder could not be read (access denied), so its contents are not counted.
    public var denied: Bool = false

    public init(name: String, parent: FolderNode?) {
        self.name = name
        self.parent = parent
    }

    /// Removes a sub-folder (after it was deleted from disk) and updates the totals of this folder and its ancestors.
    @discardableResult
    public func removeChild(_ child: FolderNode) -> Bool {
        guard let idx = children.firstIndex(where: { $0 === child }) else {
            return false
        }
        children.remove(at: idx)
        subtractFromTotals(size: child.size, files: child.fileCount)
        return true
    }

    /// Removes a listed file (after it was deleted from disk) and updates the totals.
    @discardableResult
    public func removeFile(_ fileName: String) -> Bool {
        guard let idx = files.firstIndex(where: { $0.name.caseInsensitiveCompare(fileName) == .orderedSame }) else {
            return false
        }
        let file = files.remove(at: idx)
        ownFilesSize = max(0, ownFilesSize - file.size)
        ownFileCount = max(0, ownFileCount - 1)
        subtractFromTotals(size: file.size, files: 1)
        return true
    }

    private func subtractFromTotals(size deltaSize: Int64, files deltaFiles: Int64) {
        var cur: FolderNode? = self
        while let n = cur {
            n.size = max(0, n.size - deltaSize)
            n.fileCount = max(0, n.fileCount - deltaFiles)
            cur = n.parent
        }
    }

    public func isSameOrInside(_ ancestor: FolderNode) -> Bool {
        var cur: FolderNode? = self
        while let n = cur {
            if n === ancestor { return true }
            cur = n.parent
        }
        return false
    }

    public var fullPath: String {
        var names: [String] = []
        var cur: FolderNode? = self
        while let n = cur {
            names.append(n.name)
            cur = n.parent
        }
        names.reverse()
        guard var path = names.first else { return "/" }
        for part in names.dropFirst() {
            path = PathUtil.combine(path, part)
        }
        return path
    }

    /// Finds the node for a path at or below this one; nil if it is not part of this tree.
    public func find(_ fullPath: String) -> FolderNode? {
        guard let target = try? PathUtil.normalize(fullPath) else {
            return nil
        }
        let selfPath = self.fullPath
        if target.caseInsensitiveCompare(selfPath) == .orderedSame {
            return self
        }
        if !PathUtil.isUnder(target, selfPath) {
            return nil
        }

        let suffixStart = target.index(target.startIndex, offsetBy: selfPath == "/" ? 1 : selfPath.count + 1)
        let relative = String(target[suffixStart...])
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)

        var node: FolderNode = self
        for partSub in parts {
            let part = String(partSub)
            guard let next = node.children.first(where: { $0.name.caseInsensitiveCompare(part) == .orderedSame }) else {
                return nil
            }
            node = next
        }
        return node
    }
}
