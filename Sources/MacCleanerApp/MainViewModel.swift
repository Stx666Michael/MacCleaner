import Foundation
import AppKit
import Combine
import MacCleanerCore

public enum AppState: String, Equatable {
    case home = "Home"
    case scanning = "Scanning"
    case results = "Results"
    case cleaning = "Cleaning"
    case summary = "Summary"
    case explore = "Explore"
}

@MainActor
public final class MainViewModel: ObservableObject {
    private let _rules: Rules
    private let _scanner: MacCleanerCore.Scanner
    private let _cleaner: Cleaner
    private var _scanTask: Task<Void, Never>?
    private var _cleanTask: Task<Void, Never>?
    private var _bulkChange: Bool = false
    private var _sortColumn: String = "Size"
    private var _sortDescending: Bool = true
    private var _lastCleanItems: [FindingItem] = []
    private var _lastResult: CleanResult?
    private var _activeObserver: NSObjectProtocol?

    public let isAdmin: Bool
    @Published public var hasFullDiskAccess: Bool
    public let explore: ExploreViewModel

    @Published public var state: AppState = .home {
        didSet {
            explore.isActive = (state == .explore)
        }
    }

    // ---- Home --------------------------------------------------------------------------------------
    @Published public var drives: [DriveItem] = []
    @Published public var customFolders: [String] = []
    public let thresholds: [ThresholdOption]
    @Published public var selectedThreshold: ThresholdOption

    public var canScan: Bool {
        drives.contains(where: \.isSelected) || !customFolders.isEmpty
    }

    // ---- Scanning ----------------------------------------------------------------------------------
    @Published public var scanCurrentFolder: String = ""
    @Published public var scanStats: String = ""
    @Published public var scanFound: String = ""
    @Published public var deniedFolders: Int = 0
    @Published public var scanSummary: String = ""

    // ---- Results -----------------------------------------------------------------------------------
    @Published public var items: [FindingItem] = []
    @Published public var filteredItems: [FindingItem] = []
    @Published public var categories: [CategoryGroup] = []
    @Published public var selectedCategory: CategoryGroup? {
        didSet { refreshFilteredItems() }
    }
    @Published public var searchText: String = "" {
        didSet { refreshFilteredItems() }
    }
    @Published public var selectedCount: Int = 0
    @Published public var selectedBytes: Int64 = 0
    @Published public var hasNoItems: Bool = false

    public var selectedText: String {
        selectedCount == 0
            ? "Nothing selected"
            : "\(Self.formatCount(Int64(selectedCount))) selected · \(Format.size(selectedBytes))"
    }

    public var hasSelection: Bool { selectedCount > 0 }
    public var showAdminBanner: Bool { deniedFolders > 0 && !hasFullDiskAccess }

    // ---- Confirm + Clean ---------------------------------------------------------------------------
    @Published public var showConfirm: Bool = false
    @Published public var permanentDelete: Bool = false
    @Published public var confirmTitle: String = ""
    @Published public var confirmHasBin: Bool = false
    @Published public var confirmHasReview: Bool = false
    @Published public var confirmReviewCount: Int = 0

    @Published public var cleanDone: Int = 0
    @Published public var cleanTotal: Int = 0
    @Published public var cleanCurrent: String = ""

    // ---- Summary -----------------------------------------------------------------------------------
    @Published public var failures: [FailureItem] = []
    @Published public var summaryHeadline: String = ""
    @Published public var summaryDetail: String = ""
    @Published public var summaryHasFailures: Bool = false
    @Published public var failuresTitle: String = ""

    public init(rules: Rules = Rules.createDefault()) {
        self._rules = rules
        self._scanner = MacCleanerCore.Scanner(_rules)
        self._cleaner = Cleaner(_rules)
        self.isAdmin = (geteuid() == 0)
        let fda = MacOSIntegration.hasFullDiskAccess()
        self.hasFullDiskAccess = fda
        self.explore = ExploreViewModel(rules: _rules, cleaner: _cleaner, isAdmin: self.isAdmin, hasFullDiskAccess: fda)

        self.thresholds = [
            ThresholdOption(label: "100 MB", bytes: 100 << 20),
            ThresholdOption(label: "250 MB", bytes: 250 << 20),
            ThresholdOption(label: "500 MB", bytes: 500 << 20),
            ThresholdOption(label: "1 GB", bytes: 1 << 30),
            ThresholdOption(label: "5 GB", bytes: 5 << 30)
        ]
        self.selectedThreshold = self.thresholds[2]

        self._activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = MacOSIntegration.hasFullDiskAccess()
                self.hasFullDiskAccess = granted
                self.explore.hasFullDiskAccess = granted
            }
        }

        self.explore.closeRequested = { [weak self] in
            self?.state = .home
        }

        for vol in MacOSIntegration.listVolumes() {
            let item = DriveItem(volume: vol, selected: vol.isSystemVolume) { [weak self] in
                self?.objectWillChange.send()
            }
            drives.append(item)
        }

        // Folders passed on the command line (excluding flags) are scanned instead of the system drive.
        let args = Array(CommandLine.arguments.dropFirst())
        if !args.contains("--generate-screenshots") {
            for arg in args where !arg.hasPrefix("-") {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                    for d in drives { d.isSelected = false }
                    if let norm = try? PathUtil.normalize(arg), !customFolders.contains(norm) {
                        customFolders.append(norm)
                    }
                }
            }
        }
    }

    // ---- Explore -----------------------------------------------------------------------------------
    public func exploreRoot(_ root: String) {
        state = .explore
        Task {
            await explore.startAsync(root)
        }
    }

    // ---- Home actions ------------------------------------------------------------------------------
    public func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to scan"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let path = (try? PathUtil.normalize(url.path)) ?? url.path
            if !customFolders.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                customFolders.append(path)
            }
        }
    }

    public func removeFolder(_ folder: String) {
        customFolders.removeAll { $0 == folder }
    }

    private func currentRoots() -> [String] {
        drives.filter(\.isSelected).map(\.root) + customFolders
    }

    public func scan() {
        let roots = currentRoots()
        guard !roots.isEmpty else { return }

        state = .scanning
        scanCurrentFolder = roots.first ?? ""
        scanStats = "0 files · 0 B checked"
        scanFound = "0 B cleanable found so far"

        let scanner = _scanner
        let threshold = selectedThreshold.bytes
        let task = Task { @MainActor in
            let result = await scanner.scanAsync(ScanOptions(roots: roots, largeFileThreshold: threshold)) { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.scanCurrentFolder = p.currentFolder
                    self.scanStats = "\(Self.formatCount(p.filesScanned)) files · \(Format.size(p.bytesScanned)) checked"
                    self.scanFound = "\(Format.size(p.foundBytes)) cleanable found so far"
                }
            }
            if result.cancelled || Task.isCancelled {
                self.state = .home
                return
            }
            self.loadResults(result)
            self.state = .results
        }
        _scanTask = task
    }

    public func cancelScan() {
        _scanTask?.cancel()
    }

    // ---- Results -----------------------------------------------------------------------------------
    private func matches(_ item: FindingItem) -> Bool {
        if let cat = selectedCategory, !cat.matches(item) {
            return false
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return item.name.localizedCaseInsensitiveContains(q) || item.folder.localizedCaseInsensitiveContains(q)
    }

    public func refreshFilteredItems() {
        var matching = items.filter { matches($0) }
        matching.sort { a, b in
            let cmp: Bool
            switch _sortColumn {
            case "Name":
                cmp = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "Modified":
                cmp = a.modified < b.modified
            default:
                cmp = a.size < b.size
            }
            return _sortDescending ? !cmp : cmp
        }
        filteredItems = matching
    }

    public func selectCategory(_ cat: CategoryGroup) {
        selectedCategory = cat
    }

    public func loadResults(_ result: ScanResult) {
        hasFullDiskAccess = MacOSIntegration.hasFullDiskAccess()
        _bulkChange = true
        items = result.findings.map { f in
            FindingItem(finding: f) { [weak self] item in
                self?.onItemSelectionChanged(item)
            }
        }
        _bulkChange = false

        deniedFolders = result.deniedFolders
        buildCategories()
        recomputeSelection()
        let cleanable = items.filter { !$0.isLocked }.reduce(Int64(0)) { $0 + $1.size }
        let secs = Int(round(result.elapsed))
        scanSummary = "Checked \(Self.formatCount(result.filesScanned)) files (\(Format.size(result.bytesScanned))) in \(secs)s · \(Format.size(cleanable)) can be cleaned"
        refreshFilteredItems()
    }

    private func buildCategories() {
        let previous = selectedCategory?.key
        var groups: [CategoryGroup] = []
        groups.append(CategoryGroup(key: "all", name: "All cleanable items", tier: .review) { !$0.isLocked })

        for cat in Category.allCases {
            let members = items.filter { !$0.isLocked && $0.finding.category == cat }
            if members.isEmpty { continue }
            let tier: RiskTier = members.allSatisfy { $0.tier == .safe } ? .safe : .review
            groups.append(CategoryGroup(key: cat.rawValue, name: CategoryInfo.name(cat), tier: tier) { !$0.isLocked && $0.finding.category == cat })
        }

        if items.contains(where: \.isLocked) {
            groups.append(CategoryGroup(key: "locked", name: "Protected (cannot be removed)", tier: .locked) { $0.isLocked })
        }

        for g in groups {
            g.update(items)
        }
        categories = groups
        selectedCategory = groups.first { $0.key == previous } ?? groups.first
        hasNoItems = !items.contains { !$0.isLocked }
    }

    private func onItemSelectionChanged(_ item: FindingItem) {
        if _bulkChange { return }
        selectedCount += item.isSelected ? 1 : -1
        selectedBytes += item.isSelected ? item.size : -item.size
    }

    private func recomputeSelection() {
        selectedCount = items.filter(\.isSelected).count
        selectedBytes = items.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.size }
    }

    private func setSelection(_ targetItems: [FindingItem], predicate: (FindingItem) -> Bool) {
        _bulkChange = true
        for i in targetItems {
            i.isSelected = !i.isLocked && predicate(i)
        }
        _bulkChange = false
        recomputeSelection()
        objectWillChange.send()
    }

    public func selectSafe() {
        setSelection(items) { i in
            i.tier == .safe && (isAdmin || !i.needsAdmin)
        }
    }

    public func selectVisible() {
        _bulkChange = true
        for i in filteredItems {
            i.isSelected = !i.isLocked
        }
        _bulkChange = false
        recomputeSelection()
        objectWillChange.send()
    }

    public func clearSelection() {
        setSelection(items) { _ in false }
    }

    public func sortBy(_ column: String) {
        if _sortColumn == column {
            _sortDescending.toggle()
        } else {
            _sortColumn = column
            _sortDescending = (column != "Name")
        }
        refreshFilteredItems()
    }

    public func backToHome() {
        state = .home
    }

    public func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // ---- Confirm + Clean ---------------------------------------------------------------------------
    public func requestClean() {
        let sel = items.filter(\.isSelected)
        if sel.isEmpty { return }
        let totalSize = sel.reduce(Int64(0)) { $0 + $1.size }
        confirmTitle = "Clean \(Self.formatCount(Int64(sel.count))) item\(sel.count == 1 ? "" : "s") (\(Format.size(totalSize)))?"
        confirmHasBin = sel.contains { $0.finding.category == .trash }
        confirmReviewCount = sel.filter { $0.tier == .review }.count
        confirmHasReview = confirmReviewCount > 0
        permanentDelete = false
        showConfirm = true
    }

    public func cancelConfirm() {
        showConfirm = false
    }

    public func confirmClean() {
        showConfirm = false
        _lastCleanItems = items.filter { $0.isSelected && !$0.isLocked }
        let findings = _lastCleanItems.map(\.finding)
        let mode: CleanMode = permanentDelete ? .permanent : .trash

        cleanDone = 0
        cleanTotal = findings.count
        cleanCurrent = ""
        state = .cleaning

        let cleaner = _cleaner
        let task = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                cleaner.clean(findings, mode: mode) { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.cleanDone = p.done
                        self.cleanTotal = p.total
                        self.cleanCurrent = p.current
                    }
                }
            }.value
            self.showSummary(result)
        }
        _cleanTask = task
    }

    public func cancelClean() {
        _cleanTask?.cancel()
    }

    public func showSummary(_ r: CleanResult) {
        _lastResult = r
        let recycled = (r.mode == .trash && r.bytesRecycled > 0)

        if r.mode == .permanent || r.bytesRecycled == 0 {
            summaryHeadline = "\(Format.size(r.bytesFreed)) freed"
        } else {
            summaryHeadline = "\(Format.size(r.bytesRecycled)) moved to the Trash"
        }

        var parts: [String] = ["\(Self.formatCount(Int64(r.itemsCleaned))) item\(r.itemsCleaned == 1 ? "" : "s") cleaned"]
        if recycled {
            parts.append("Space is freed once you empty the Trash")
        }
        if r.bytesFreed > 0 && r.mode == .trash {
            parts.append("\(Format.size(r.bytesFreed)) permanently removed (Trash emptied)")
        }
        if r.cancelled {
            parts.append("Cancelled before finishing")
        }
        summaryDetail = parts.joined(separator: " · ")

        failures = r.failures.map { FailureItem(path: $0.path, reason: $0.reason) }
        summaryHasFailures = !failures.isEmpty
        failuresTitle = "\(Self.formatCount(Int64(failures.count))) item\(failures.count == 1 ? " was" : "s were") skipped or only partly cleaned"
        state = .summary
    }

    public func backToResults() {
        if let r = _lastResult {
            let gone = Set(r.cleanedPaths.map { $0.lowercased() })
            _bulkChange = true
            let toRemove = Set(_lastCleanItems.filter { gone.contains($0.finding.path.lowercased()) }.map(\.id))
            items.removeAll { toRemove.contains($0.id) }
            _bulkChange = false
            _lastCleanItems = []
            buildCategories()
            recomputeSelection()
            refreshFilteredItems()
        }
        state = .results
    }

    public func openLog() {
        let path = _lastResult?.logPath ?? Cleaner.defaultLogPath
        if FileManager.default.fileExists(atPath: path) {
            MacOSIntegration.openFile(path)
        }
    }

    private static func formatCount(_ n: Int64) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
