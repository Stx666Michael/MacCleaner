import Foundation
import Combine
import MacCleanerCore

@MainActor
public final class DriveItem: ObservableObject, Identifiable {
    public nonisolated var id: String { root }
    public let root: String
    public let title: String
    public let usedPercent: Double
    public let usageText: String
    private let onSelectionChanged: () -> Void

    @Published public var isSelected: Bool {
        didSet {
            if oldValue != isSelected {
                onSelectionChanged()
            }
        }
    }

    public init(volume: VolumeInfo, selected: Bool, onSelectionChanged: @escaping () -> Void = {}) {
        self.root = volume.root
        let label = volume.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Local Disk" : volume.name
        self.title = "\(label) (\(volume.root))"
        let total = volume.totalBytes
        let free = volume.freeBytes
        self.usedPercent = total > 0 ? Double(total - free) * 100.0 / Double(total) : 0
        self.usageText = "\(Format.size(free)) free of \(Format.size(total))"
        self.isSelected = selected
        self.onSelectionChanged = onSelectionChanged
    }

    public func toggle() {
        isSelected.toggle()
    }
}

@MainActor
public final class FindingItem: ObservableObject, Identifiable {
    public nonisolated var id: String { finding.path + "::" + finding.category.rawValue }
    private let selectionChanged: (FindingItem) -> Void

    public let finding: Finding
    public let name: String
    public let folder: String
    public var reason: String { finding.reason }
    public var size: Int64 { finding.size }
    public let sizeText: String
    public let modified: Date
    public let modifiedText: String
    public var tier: RiskTier { finding.tier }
    public var tierText: String { finding.tier.rawValue }
    public var isLocked: Bool { finding.tier == .locked }
    public var needsAdmin: Bool { finding.needsAdmin }

    @Published public var isSelected: Bool = false {
        didSet {
            if oldValue != isSelected {
                selectionChanged(self)
            }
        }
    }

    public init(finding: Finding, selectionChanged: @escaping (FindingItem) -> Void) {
        self.finding = finding
        self.selectionChanged = selectionChanged
        self.name = finding.label ?? (finding.path as NSString).lastPathComponent
        if finding.contentsOnly {
            self.folder = finding.path
        } else {
            let parent = (finding.path as NSString).deletingLastPathComponent
            self.folder = parent.isEmpty ? finding.path : parent
        }
        self.sizeText = Format.size(finding.size)
        self.modified = finding.modifiedUtc
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        self.modifiedText = fmt.string(from: finding.modifiedUtc)
    }

    public func openLocation() {
        if finding.category == .trash {
            MacOSIntegration.revealInFinder(MacOSIntegration.userTrashPath, selectFile: false)
        } else if finding.contentsOnly {
            MacOSIntegration.revealInFinder(finding.path, selectFile: false)
        } else {
            MacOSIntegration.revealInFinder(finding.path, selectFile: true)
        }
    }
}

/// One row in the left-hand list: a category, "All", or the protected items.
@MainActor
public final class CategoryGroup: ObservableObject, Identifiable, Equatable {
    public nonisolated var id: String { key }
    public let key: String
    public let name: String
    public let tier: RiskTier
    public let matches: (FindingItem) -> Bool

    @Published public var count: Int = 0
    @Published public var sizeText: String = ""

    public init(key: String, name: String, tier: RiskTier, matches: @escaping (FindingItem) -> Bool) {
        self.key = key
        self.name = name
        self.tier = tier
        self.matches = matches
    }

    public func update(_ all: [FindingItem]) {
        var bytes: Int64 = 0
        var n = 0
        for item in all where matches(item) {
            n += 1
            bytes += item.size
        }
        count = n
        sizeText = Format.size(bytes)
    }

    public nonisolated static func == (lhs: CategoryGroup, rhs: CategoryGroup) -> Bool {
        lhs.key == rhs.key
    }
}

public struct ThresholdOption: Identifiable, Equatable, Hashable {
    public var id: Int64 { bytes }
    public let label: String
    public let bytes: Int64

    public init(label: String, bytes: Int64) {
        self.label = label
        self.bytes = bytes
    }
}

public struct FailureItem: Identifiable, Equatable {
    public var id: String { path + "::" + reason }
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}
