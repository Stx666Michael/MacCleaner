import Foundation
import Darwin
import Combine
import MacCleanerCore

/// Interactive disk-space explorer: a treemap and list of the current folder, with history, breadcrumbs and delete.
@MainActor
public final class ExploreViewModel: ObservableObject {
    private static let maxRows = 400

    private let _scanner = FolderTreeScanner()
    private let _rules: Rules
    private let _cleaner: Cleaner
    private var _back: [FolderNode] = []
    private var _forward: [FolderNode] = []
    private var _scanTask: Task<Void, Never>?
    private var _deleteTarget: ExploreItem?
    private var _currentDeleteBlock: String?

    public let isAdmin: Bool
    @Published public var hasFullDiskAccess: Bool
    public var closeRequested: (() -> Void)?

    @Published public var isActive: Bool = false

    // ---- scanning ------------------------------------------------------------------------------------
    @Published public var isScanning: Bool = false
    @Published public var scanStats: String = ""
    @Published public var scanCurrent: String = ""
    @Published public var deniedFolders: Int = 0
    public var showAdminHint: Bool { deniedFolders > 0 && !hasFullDiskAccess }

    // ---- current folder ------------------------------------------------------------------------------
    @Published public var root: FolderNode?
    @Published public var current: FolderNode?
    @Published public var title: String = ""
    @Published public var summary: String = ""
    @Published public var isEmpty: Bool = false
    @Published public var emptyText: String = ""
    @Published public var items: [ExploreItem] = []
    @Published public var hoverItem: ExploreItem? {
        didSet {
            oldValue?.isHot = false
            hoverItem?.isHot = true
        }
    }
    @Published public var crumbs: [Crumb] = []

    // ---- status banner -------------------------------------------------------------------------------
    @Published public var status: String = ""
    @Published public var statusNeedsRescan: Bool = false
    public var hasStatus: Bool { !status.isEmpty }

    // ---- delete --------------------------------------------------------------------------------------
    @Published public var showDeleteConfirm: Bool = false
    @Published public var deletePermanent: Bool = false
    @Published public var isDeleting: Bool = false
    @Published public var deleteTitle: String = ""
    @Published public var deleteDetail: String = ""
    @Published public var deletingName: String = ""

    public init(rules: Rules, cleaner: Cleaner, isAdmin: Bool, hasFullDiskAccess: Bool = MacOSIntegration.hasFullDiskAccess()) {
        self._rules = rules
        self._cleaner = cleaner
        self.isAdmin = isAdmin
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    public func startAsync(_ rootPath: String, keepLocation: Bool = false) async {
        hasFullDiskAccess = MacOSIntegration.hasFullDiskAccess()
        let keep = keepLocation ? current?.fullPath : nil
        clearStatus()
        isScanning = true
        scanStats = "0 files · 0 B mapped"
        scanCurrent = rootPath

        let scanner = _scanner
        let task = Task { @MainActor in
            do {
                let result = try await scanner.scanAsync(rootPath) { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.scanStats = "\(Self.formatCount(p.files)) files · \(Format.size(p.bytes)) mapped"
                        self.scanCurrent = p.currentFolder
                    }
                }
                self.isScanning = false
                if result.cancelled || Task.isCancelled {
                    if self.root == nil || !keepLocation {
                        self.closeRequested?()
                    }
                    return
                }
                self.root = result.root
                self.deniedFolders = result.deniedFolders
                self.title = result.root.fullPath
                self._back.removeAll()
                self._forward.removeAll()
                let targetNode = keep.flatMap { result.root.find($0) } ?? result.root
                self.setCurrent(targetNode)
            } catch {
                self.isScanning = false
                self.closeRequested?()
            }
        }
        _scanTask = task
        await task.value
    }

    public func cancelScan() {
        _scanTask?.cancel()
    }

    public func rescan() {
        guard let r = root else { return }
        Task {
            await startAsync(r.fullPath, keepLocation: true)
        }
    }

    public func close() {
        _scanTask?.cancel()
        closeRequested?()
    }

    public func setCurrent(_ node: FolderNode) {
        current = node
        hoverItem = nil
        if node === root {
            _currentDeleteBlock = "This is the folder you are exploring"
        } else {
            _currentDeleteBlock = _rules.getDeleteBlockReason(node.fullPath)
        }
        buildItems()
        buildCrumbs()

        let filesLabel = node.fileCount == 1 ? "file" : "files"
        var sum = "\(Format.size(node.size)) in \(Self.formatCount(node.fileCount)) \(filesLabel)"
        if let root, root.size > 0, !(node === root) {
            let pct = Double(node.size) * 100.0 / Double(root.size)
            let pctStr = String(format: "%.1f", pct).replacingOccurrences(of: ".0", with: "")
            sum += " · \(pctStr)% of \(root.name)"
        }
        summary = sum
        isEmpty = !items.contains { $0.size > 0 }
        emptyText = node.denied ? "This folder could not be read (access denied)." : "This folder is empty."
        objectWillChange.send()
    }

    private func buildItems() {
        guard let cur = current else {
            items = []
            return
        }
        let curPath = cur.fullPath
        let total = Double(cur.size)

        struct RawEntry {
            let kind: ExploreKind
            let name: String
            let size: Int64
            let node: FolderNode?
            let file: String?
        }

        var all: [RawEntry] = []
        for c in cur.children {
            all.append(RawEntry(kind: .folder, name: c.name, size: c.size, node: c, file: nil))
        }
        for f in cur.files {
            all.append(RawEntry(kind: .file, name: f.name, size: f.size, node: nil, file: f.name))
        }
        if cur.otherFileCount > 0 {
            all.append(
                RawEntry(
                    kind: .others,
                    name: "\(Self.formatCount(Int64(cur.otherFileCount))) other files",
                    size: cur.otherFilesSize,
                    node: nil,
                    file: nil
                )
            )
        }

        let sorted = all.sorted { $0.size > $1.size }
        var list: [ExploreItem] = []
        var folderRank = 0
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        for a in sorted.prefix(Self.maxRows) {
            let path: String? = (a.kind == .others) ? nil : PathUtil.combine(curPath, a.name)
            let lockReason: String? = path.flatMap { _rules.getDeleteBlockReason($0) }
            let pct = total > 0 ? Double(a.size) * 100.0 / total : 0

            let detail: String
            let color: RGBColor
            switch a.kind {
            case .folder:
                let fc = a.node?.fileCount ?? 0
                let deniedSuffix = (a.node?.denied == true) ? " · access denied" : ""
                detail = "\(Self.formatCount(fc)) file\(fc == 1 ? "" : "s")\(deniedSuffix)"
                color = Theme.folderPalette[folderRank % Theme.folderPalette.count]
                folderRank += 1
            case .file:
                if let entry = cur.files.first(where: { $0.name == a.file }) {
                    detail = dateFmt.string(from: entry.modifiedUtc)
                } else {
                    detail = ""
                }
                color = Theme.fileColor
            case .others:
                detail = "Files too small to list one by one"
                color = Theme.otherColor
            }

            list.append(
                ExploreItem(
                    kind: a.kind,
                    name: a.name,
                    size: a.size,
                    percent: pct,
                    detail: detail,
                    rgbColor: color,
                    path: path,
                    lockReason: lockReason,
                    node: a.node,
                    fileName: a.file,
                    navigate: { [weak self] item in self?.openItem(item) },
                    reveal: { [weak self] item in self?.revealItem(item) },
                    delete: { [weak self] item in self?.requestDelete(item) }
                )
            )
        }

        if sorted.count > Self.maxRows {
            let rest = sorted.dropFirst(Self.maxRows)
            let restSize = rest.reduce(Int64(0)) { $0 + $1.size }
            list.append(
                ExploreItem(
                    kind: .others,
                    name: "\(Self.formatCount(Int64(rest.count))) smaller items",
                    size: restSize,
                    percent: total > 0 ? Double(restSize) * 100.0 / total : 0,
                    detail: "Too small to list one by one",
                    rgbColor: Theme.otherColor,
                    path: nil,
                    lockReason: nil,
                    node: nil,
                    fileName: nil,
                    navigate: { [weak self] item in self?.openItem(item) },
                    reveal: { [weak self] item in self?.revealItem(item) },
                    delete: { [weak self] item in self?.requestDelete(item) }
                )
            )
        }
        items = list
    }

    private func buildCrumbs() {
        var chain: [FolderNode] = []
        var cur = current
        while let n = cur {
            chain.append(n)
            cur = n.parent
        }
        chain.reverse()
        crumbs = chain.enumerated().map { idx, node in
            Crumb(node: node, text: node.name, isLast: idx == chain.count - 1) { [weak self] target in
                self?.navigateTo(target)
            }
        }
    }

    // ---- navigation ----------------------------------------------------------------------------------
    public var canGoBack: Bool { isActive && !_back.isEmpty }
    public var canGoForward: Bool { isActive && !_forward.isEmpty }
    public var canGoUp: Bool { isActive && current?.parent != nil }

    private func openItem(_ item: ExploreItem) {
        if item.isFolder, let node = item.node {
            navigateTo(node)
        }
    }

    public func navigateTo(_ node: FolderNode) {
        guard let cur = current, !(node === cur) else { return }
        _back.append(cur)
        _forward.removeAll()
        setCurrent(node)
    }

    public func goBack() {
        guard let cur = current, let target = _back.popLast() else { return }
        _forward.append(cur)
        setCurrent(target)
    }

    public func goForward() {
        guard let cur = current, let target = _forward.popLast() else { return }
        _back.append(cur)
        setCurrent(target)
    }

    public func goUp() {
        if let parent = current?.parent {
            navigateTo(parent)
        }
    }

    // ---- Finder integration --------------------------------------------------------------------------
    public func openCurrentInFinder() {
        if let cur = current {
            MacOSIntegration.revealInFinder(cur.fullPath, selectFile: false)
        }
    }

    private func revealItem(_ item: ExploreItem) {
        guard let path = item.path else {
            openCurrentInFinder()
            return
        }
        if item.isFolder {
            MacOSIntegration.revealInFinder(path, selectFile: false)
        } else {
            MacOSIntegration.revealInFinder(path, selectFile: true)
        }
    }

    // ---- status banner -------------------------------------------------------------------------------
    private func setStatus(_ text: String, needsRescan: Bool = false) {
        status = text
        statusNeedsRescan = needsRescan
    }

    public func clearStatus() {
        setStatus("")
    }

    // ---- delete --------------------------------------------------------------------------------------
    public var canDeleteCurrent: Bool {
        isActive && current != nil && !isScanning && _currentDeleteBlock == nil
    }

    public var deleteFolderTip: String {
        _currentDeleteBlock ?? "Delete this folder…"
    }

    public func requestDelete(_ item: ExploreItem) {
        guard item.canDelete, let path = item.path, !showDeleteConfirm, !isDeleting else { return }
        _deleteTarget = item
        deleteTitle = "Delete “\(item.name)”?"
        if item.isFolder, let node = item.node {
            let fc = node.fileCount
            deleteDetail = "\(item.sizeText) in \(Self.formatCount(fc)) file\(fc == 1 ? "" : "s")\n\(path)"
        } else {
            deleteDetail = "\(item.sizeText)\n\(path)"
        }
        deletePermanent = false
        showDeleteConfirm = true
    }

    public func deleteFolder() {
        guard let cur = current, canDeleteCurrent else { return }
        let wrapper = ExploreItem(
            kind: .folder,
            name: cur.name,
            size: cur.size,
            percent: 100,
            detail: "",
            rgbColor: Theme.folderPalette[0],
            path: cur.fullPath,
            lockReason: _currentDeleteBlock,
            node: cur,
            fileName: nil,
            navigate: { [weak self] i in self?.openItem(i) },
            reveal: { [weak self] i in self?.revealItem(i) },
            delete: { [weak self] i in self?.requestDelete(i) }
        )
        requestDelete(wrapper)
    }

    public func deleteHovered() {
        guard isActive, !isScanning, !showDeleteConfirm, !isDeleting else { return }
        if let item = hoverItem, item.canDelete {
            requestDelete(item)
        }
    }

    public func cancelDelete() {
        showDeleteConfirm = false
    }

    public func confirmDelete() {
        guard let item = _deleteTarget, item.path != nil else { return }
        showDeleteConfirm = false
        deletingName = item.name
        isDeleting = true

        let finding = Self.buildFinding(item)
        let mode: CleanMode = deletePermanent ? .permanent : .trash
        let cleaner = _cleaner

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                cleaner.clean([finding], mode: mode)
            }.value
            self.isDeleting = false
            self.applyDeleteResult(item: item, result: result, mode: mode)
        }
    }

    private static func buildFinding(_ item: ExploreItem) -> Finding {
        let path = item.path!
        var st = stat()
        let exists = (lstat(path, &st) == 0)
        let stamp = exists
            ? Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0)
            : Date()
        if item.isFolder {
            return Finding(
                path: path,
                isDirectory: true,
                size: item.size,
                modifiedUtc: stamp,
                stampUtc: stamp,
                category: .largeFile,
                tier: .review,
                reason: "Deleted from the explorer"
            )
        }
        let length = exists ? Int64(st.st_size) : item.size
        return Finding(
            path: path,
            isDirectory: false,
            size: length,
            modifiedUtc: stamp,
            stampUtc: stamp,
            category: .largeFile,
            tier: .review,
            reason: "Deleted from the explorer"
        )
    }

    private func applyDeleteResult(item: ExploreItem, result: CleanResult, mode: CleanMode) {
        let cleaned = result.cleanedPaths.contains { $0.caseInsensitiveCompare(item.path ?? "") == .orderedSame }
        if cleaned {
            removeFromTree(item)
            if mode == .trash {
                setStatus("Moved “\(item.name)” (\(item.sizeText)) to the Trash. The space is freed once you empty it.")
            } else {
                setStatus("Deleted “\(item.name)” (\(item.sizeText)).")
            }
            return
        }

        let reason = result.failures.first?.reason ?? "unknown reason"
        if reason.localizedCaseInsensitiveContains("no longer exists") || reason.caseInsensitiveCompare("Already gone") == .orderedSame {
            removeFromTree(item)
            setStatus("“\(item.name)” was already gone.")
        } else if reason.lowercased().hasPrefix("partly cleaned") {
            setStatus("“\(item.name)” was only partly deleted. \(reason) Rescan to refresh the sizes.", needsRescan: true)
        } else {
            setStatus("Could not delete “\(item.name)”: \(reason)")
        }
    }

    private func removeFromTree(_ item: ExploreItem) {
        guard let cur = current else { return }
        if item.isFolder, let node = item.node, let parent = node.parent {
            parent.removeChild(node)
            _back.removeAll { $0.isSameOrInside(node) }
            _forward.removeAll { $0.isSameOrInside(node) }
            setCurrent(cur.isSameOrInside(node) ? parent : cur)
        } else if let fileName = item.fileName {
            cur.removeFile(fileName)
            setCurrent(cur)
        }
    }

    private static func formatCount(_ n: Int64) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
