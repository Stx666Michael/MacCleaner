import SwiftUI
import MacCleanerCore

public enum ExploreKind: Equatable, Sendable {
    case folder
    case file
    case others
}

/// One block in the treemap and one row in the list: a sub-folder, a file, or a group of small ones.
@MainActor
public final class ExploreItem: ObservableObject, Identifiable {
    public nonisolated let id = UUID()
    private let _navigate: (ExploreItem) -> Void
    private let _reveal: (ExploreItem) -> Void
    private let _delete: (ExploreItem) -> Void

    public let kind: ExploreKind
    public let name: String
    public let size: Int64
    public let percent: Double
    public let detail: String
    public let rgbColor: RGBColor
    public var color: Color { rgbColor.color }

    /// Full path on disk; nil for the "other files" / "smaller items" groups.
    public let path: String?
    public let node: FolderNode?
    public let fileName: String?

    /// Why this item may not be deleted (protected system location, etc.); nil if it may be.
    public let lockReason: String?

    public var isFolder: Bool { kind == .folder }
    public var showDelete: Bool { kind != .others }
    public var canDelete: Bool { showDelete && lockReason == nil }
    public var deleteTip: String { canDelete ? "Delete…" : (lockReason ?? "") }
    public var sizeText: String { Format.size(size) }
    public var percentText: String {
        if size > 0 && percent < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", percent).replacingOccurrences(of: ".0%", with: "%")
    }

    /// True while the pointer is over this item in either the treemap or the list.
    @Published public var isHot: Bool = false

    public init(
        kind: ExploreKind,
        name: String,
        size: Int64,
        percent: Double,
        detail: String,
        rgbColor: RGBColor,
        path: String?,
        lockReason: String?,
        node: FolderNode?,
        fileName: String?,
        navigate: @escaping (ExploreItem) -> Void,
        reveal: @escaping (ExploreItem) -> Void,
        delete: @escaping (ExploreItem) -> Void
    ) {
        self.kind = kind
        self.name = name
        self.size = size
        self.percent = percent
        self.detail = detail
        self.rgbColor = rgbColor
        self.path = path
        self.lockReason = lockReason
        self.node = node
        self.fileName = fileName
        self._navigate = navigate
        self._reveal = reveal
        self._delete = delete
    }

    public func navigate() {
        if isFolder {
            _navigate(self)
        }
    }

    public func reveal() {
        _reveal(self)
    }

    public func delete() {
        if canDelete {
            _delete(self)
        }
    }
}

/// One clickable segment of the path bar.
@MainActor
public struct Crumb: Identifiable {
    public nonisolated let id = UUID()
    public let node: FolderNode
    public let text: String
    public let isLast: Bool
    public let navigate: () -> Void

    public init(node: FolderNode, text: String, isLast: Bool, navigate: @escaping (FolderNode) -> Void) {
        self.node = node
        self.text = text
        self.isLast = isLast
        self.navigate = { navigate(node) }
    }
}
