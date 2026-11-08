import SwiftUI
import MacCleanerCore

private struct ScreenshotModeKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    public var isScreenshotMode: Bool {
        get { self[ScreenshotModeKey.self] }
        set { self[ScreenshotModeKey.self] = newValue }
    }
}

@MainActor
private struct AdaptiveScrollView<Content: View>: View {
    @Environment(\.isScreenshotMode) private var isScreenshotMode
    let axes: Axis.Set
    let content: Content

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    var body: some View {
        if isScreenshotMode {
            if axes == .horizontal {
                HStack(spacing: 0) {
                    content
                    Spacer(minLength: 0)
                }
                .clipped()
            } else {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        content
                        Spacer(minLength: 0)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
                }
            }
        } else {
            ScrollView(axes, showsIndicators: axes == .vertical) {
                content
            }
        }
    }
}

@MainActor
public struct MainWindowView: View {
    @Environment(\.isScreenshotMode) private var isScreenshotMode
    @ObservedObject public var vm: MainViewModel
    @ObservedObject private var explore: ExploreViewModel

    public init(vm: MainViewModel) {
        self.vm = vm
        self.explore = vm.explore
    }

    public var body: some View {
        ZStack {
            Theme.windowBg.ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar
                ZStack {
                    switch vm.state {
                    case .home:
                        homeView
                    case .scanning:
                        scanningView
                    case .results:
                        resultsView
                    case .cleaning:
                        cleaningView
                    case .summary:
                        summaryView
                    case .explore:
                        exploreView
                    }

                    if vm.showConfirm {
                        confirmCleanModal
                    }
                    if explore.showDeleteConfirm {
                        confirmExploreDeleteModal
                    }
                    if explore.isDeleting {
                        deletingOverlay
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(keyboardShortcutsBridge)
    }

    // MARK: - Title Bar
    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("MacCleaner")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Keyboard Shortcuts Bridge
    private var keyboardShortcutsBridge: some View {
        Group {
            Button("") { explore.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
            Button("") { explore.goForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
            Button("") { explore.goUp() }
                .keyboardShortcut(.upArrow, modifiers: [.option])
            Button("") { explore.goUp() }
                .keyboardShortcut(.delete, modifiers: [])
            Button("") { explore.deleteHovered() }
                .keyboardShortcut(.deleteForward, modifiers: [])
            Button("") { explore.deleteHovered() }
                .keyboardShortcut(.delete, modifiers: [.command])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - 1. HOME
    private var homeView: some View {
        AdaptiveScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Free up disk space")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Text("Scan to find junk and large files. Nothing is removed until you pick it and confirm.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 6)
                    .padding(.bottom, 28)

                Text("Where to scan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.bottom, 8)

                ForEach(vm.drives) { drive in
                    DriveCardView(drive: drive) {
                        vm.exploreRoot(drive.root)
                    }
                    .padding(.bottom, 8)
                }

                ForEach(vm.customFolders, id: \.self) { folder in
                    CustomFolderCardView(
                        folder: folder,
                        onExplore: { vm.exploreRoot(folder) },
                        onRemove: { vm.removeFolder(folder) }
                    )
                    .padding(.bottom, 8)
                }

                SecondaryActionButton(title: "Add folder…", systemImage: "folder.badge.plus") {
                    vm.addFolder()
                }
                .padding(.top, 4)

                HStack(spacing: 12) {
                    Text("Flag files larger than")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textPrimary)

                    Menu {
                        ForEach(vm.thresholds) { t in
                            Button(t.label) {
                                vm.selectedThreshold = t
                            }
                        }
                    } label: {
                        HStack {
                            Text(vm.selectedThreshold.label)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(width: 120)
                        .background(Theme.cardBg)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardStroke, lineWidth: 1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 28)

                PrimaryActionButton(
                    title: "Scan",
                    systemImage: "magnifyingglass",
                    minWidth: 180,
                    height: 40,
                    disabled: !vm.canScan
                ) {
                    vm.scan()
                }
                .padding(.top, 28)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 2. SCANNING
    private var scanningView: some View {
        VStack(spacing: 0) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.6)
                .frame(width: 64, height: 64)

            Text("Scanning…")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.top, 20)
                .padding(.bottom, 8)

            Text(vm.scanFound)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundColor(Theme.textPrimary)

            Text(vm.scanStats)
                .font(.system(size: 13).monospacedDigit())
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 6)

            Text(vm.scanCurrentFolder)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 640)
                .padding(.top, 16)

            SecondaryActionButton(title: "Cancel", minWidth: 120) {
                vm.cancelScan()
            }
            .padding(.top, 28)
        }
        .padding(32)
    }

    // MARK: - 3. RESULTS
    private var resultsView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan results")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(vm.scanSummary)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                SecondaryActionButton(title: "New scan", systemImage: "arrow.clockwise") {
                    vm.backToHome()
                }
            }
            .padding(.bottom, 12)

            // Optional Full Disk Access Banner
            if vm.showAdminBanner {
                HStack(spacing: 12) {
                    Text("\(vm.deniedFolders) folders could not be read. Grant Full Disk Access in System Settings to include protected app caches.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    SecondaryActionButton(title: "Full Disk Access", systemImage: "lock.shield") {
                        vm.openFullDiskAccess()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.cardBg)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
                .cornerRadius(8)
                .padding(.bottom, 12)
            }

            // Main content: Categories sidebar + Items list
            HStack(spacing: 16) {
                // Left Categories Card
                AdaptiveScrollView {
                    VStack(spacing: 2) {
                        ForEach(vm.categories) { cat in
                            CategoryRowView(
                                group: cat,
                                isSelected: vm.selectedCategory?.key == cat.key
                            ) {
                                vm.selectCategory(cat)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 264)
                .background(Theme.cardBg)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
                .cornerRadius(8)

                // Right Items Pane
                VStack(spacing: 0) {
                    // Search + Bulk Buttons
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                            if isScreenshotMode {
                                Text(vm.searchText.isEmpty ? "Search by name or folder" : vm.searchText)
                                    .font(.system(size: 13))
                                    .foregroundColor(vm.searchText.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                TextField("Search by name or folder", text: $vm.searchText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textPrimary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.cardBg)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardStroke, lineWidth: 1))
                        .cornerRadius(6)

                        SecondaryActionButton(title: "Select safe items") {
                            vm.selectSafe()
                        }
                        SecondaryActionButton(title: "Select all shown") {
                            vm.selectVisible()
                        }
                        SecondaryActionButton(title: "Clear") {
                            vm.clearSelection()
                        }
                    }
                    .padding(.bottom, 10)

                    // Column headers
                    HStack(spacing: 0) {
                        Spacer().frame(width: 40)
                        Button { vm.sortBy("Name") } label: {
                            Text("Name ⇅")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button { vm.sortBy("Size") } label: {
                            Text("Size ⇅")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 90, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button { vm.sortBy("Modified") } label: {
                            Text("Modified ⇅")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 100, alignment: .center)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Text("Risk")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 80, alignment: .center)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                    // Items card
                    ZStack {
                        AdaptiveScrollView {
                            VStack(spacing: 2) {
                                ForEach(vm.filteredItems) { item in
                                    FindingRowView(item: item)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                        }

                        if vm.hasNoItems {
                            Text("Nothing to clean here. Your drives look tidy.")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.cardBg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
                    .cornerRadius(8)
                }
            }

            // Bottom Action Bar
            HStack {
                Text(vm.selectedText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                PrimaryActionButton(
                    title: "Clean selected",
                    systemImage: "trash",
                    minWidth: 170,
                    height: 36,
                    disabled: !vm.hasSelection
                ) {
                    vm.requestClean()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.cardBg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
            .cornerRadius(8)
            .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    // MARK: - 4. CLEANING
    private var cleaningView: some View {
        VStack(spacing: 0) {
            Text("Cleaning…")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            ProgressView(value: Double(vm.cleanDone), total: Double(max(1, vm.cleanTotal)))
                .tint(Theme.accent)
                .frame(width: 480)
                .padding(.top, 24)
                .padding(.bottom, 10)

            Text("\(vm.cleanDone) of \(vm.cleanTotal)")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)

            Text(vm.cleanCurrent)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 480)
                .padding(.top, 8)

            SecondaryActionButton(title: "Stop", minWidth: 120) {
                vm.cancelClean()
            }
            .padding(.top, 24)
        }
    }

    // MARK: - 5. SUMMARY
    private var summaryView: some View {
        AdaptiveScrollView {
            VStack(spacing: 0) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundColor(Theme.safe)

                Text(vm.summaryHeadline)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                Text(vm.summaryDetail)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                if vm.summaryHasFailures {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(vm.failuresTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text("Files in use, protected, or changed since the scan are left untouched.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .padding(.bottom, 4)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(vm.failures) { f in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.path)
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(f.reason)
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.textSecondary)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                    .padding(16)
                    .frame(maxWidth: 640, alignment: .leading)
                    .background(Theme.cardBg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
                    .cornerRadius(8)
                    .padding(.top, 28)
                }

                HStack(spacing: 10) {
                    PrimaryActionButton(title: "Back to results", minWidth: 140, height: 36) {
                        vm.backToResults()
                    }
                    SecondaryActionButton(title: "Open log", minWidth: 96, height: 36) {
                        vm.openLog()
                    }
                    SecondaryActionButton(title: "Done", minWidth: 88, height: 36) {
                        vm.backToHome()
                    }
                }
                .padding(.top, 28)
            }
            .padding(.top, 120)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 6. EXPLORE
    private var exploreView: some View {
        ZStack {
            if explore.isScanning {
                VStack(spacing: 0) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.6)
                        .frame(width: 64, height: 64)

                    Text("Mapping disk space…")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                    Text(explore.scanStats)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundColor(Theme.textSecondary)

                    Text(explore.scanCurrent)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 640)
                        .padding(.top, 14)

                    SecondaryActionButton(title: "Cancel", minWidth: 120) {
                        explore.cancelScan()
                    }
                    .padding(.top, 28)
                }
            } else {
                VStack(spacing: 0) {
                    // Header
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Explore disk space")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            Text(explore.title)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            SecondaryActionButton(title: "Rescan", systemImage: "arrow.clockwise") {
                                explore.rescan()
                            }
                            SecondaryActionButton(title: "Close", systemImage: "xmark") {
                                explore.close()
                            }
                        }
                    }
                    .padding(.bottom, 10)

                    // Navigation bar: Back / Forward / Up, Breadcrumbs, Open in Finder / Delete folder
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            IconButton(systemImage: "arrow.left", disabled: !explore.canGoBack, help: "Back (Opt+Left)") {
                                explore.goBack()
                            }
                            IconButton(systemImage: "arrow.right", disabled: !explore.canGoForward, help: "Forward (Opt+Right)") {
                                explore.goForward()
                            }
                            IconButton(systemImage: "arrow.up", disabled: !explore.canGoUp, help: "Up one level (Backspace or Opt+Up)") {
                                explore.goUp()
                            }
                        }

                        AdaptiveScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(explore.crumbs) { crumb in
                                    Button {
                                        crumb.navigate()
                                    } label: {
                                        Text(crumb.text)
                                            .font(.system(size: 13))
                                            .foregroundColor(Theme.textPrimary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.001))
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)

                                    if !crumb.isLast {
                                        Text("›")
                                            .font(.system(size: 14))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                }
                            }
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            SecondaryActionButton(title: "Open in Finder", systemImage: "folder") {
                                explore.openCurrentInFinder()
                            }
                            SecondaryActionButton(
                                title: "Delete folder",
                                systemImage: "trash",
                                disabled: !explore.canDeleteCurrent,
                                help: explore.deleteFolderTip
                            ) {
                                explore.deleteFolder()
                            }
                        }
                    }
                    .padding(.bottom, 8)

                    // Status banner after deletion
                    if explore.hasStatus {
                        HStack(spacing: 12) {
                            Text(explore.status)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if explore.statusNeedsRescan {
                                SecondaryActionButton(title: "Rescan") {
                                    explore.rescan()
                                }
                            }
                            Button {
                                explore.clearStatus()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                                    .padding(6)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.cardBg)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
                        .cornerRadius(8)
                        .padding(.bottom, 8)
                    }

                    // Size summary
                    HStack {
                        Text(explore.summary)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        if explore.showAdminHint {
                            HStack(spacing: 10) {
                                Text("\(explore.deniedFolders) folders could not be read")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                                SecondaryActionButton(title: "Full Disk Access", systemImage: "lock.shield") {
                                    vm.openFullDiskAccess()
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)

                    // Split View: Treemap + Right Folder List
                    HStack(spacing: 14) {
                        // Left Treemap Card
                        ZStack {
                            TreemapView(items: explore.items, hoverItem: $explore.hoverItem)
                                .padding(6)
                            if explore.isEmpty {
                                Text(explore.emptyText)
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.cardBg)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
                        .cornerRadius(8)

                        // Right List Card
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("In this folder")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text("Click a folder to open it. Right-click for more. Press Delete while hovering to remove.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 8)

                            AdaptiveScrollView {
                                VStack(spacing: 2) {
                                    ForEach(explore.items) { item in
                                        ExploreRowView(
                                            item: item,
                                            onHoverChanged: { hovering in
                                                if hovering {
                                                    explore.hoverItem = item
                                                } else if explore.hoverItem === item {
                                                    explore.hoverItem = nil
                                                }
                                            }
                                        )
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.bottom, 6)
                            }
                        }
                        .frame(width: 360)
                        .frame(maxHeight: .infinity)
                        .background(Theme.cardBg)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - 7. CONFIRM CLEAN MODAL
    private var confirmCleanModal: some View {
        ZStack {
            Theme.modalBackdrop.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text(vm.confirmTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                VStack(alignment: .leading, spacing: 10) {
                    RadioOptionRow(
                        selected: !vm.permanentDelete,
                        title: "Move to Trash (recommended)"
                    ) {
                        vm.permanentDelete = false
                    }
                    RadioOptionRow(
                        selected: vm.permanentDelete,
                        title: "Delete permanently"
                    ) {
                        vm.permanentDelete = true
                    }
                }
                .padding(.top, 18)

                if !vm.permanentDelete {
                    Text("You can restore these from the Trash. Disk space is only freed once the Trash is emptied.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 14)
                } else {
                    Text("Permanently deleted files cannot be restored.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.review)
                        .padding(.top, 14)
                }

                if vm.confirmHasBin {
                    Text("Emptying the Trash is always permanent.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.review)
                        .padding(.top, 10)
                }

                if vm.confirmHasReview {
                    Text("\(vm.confirmReviewCount) selected items are marked Review: files from your own folders. Make sure you do not need them.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 10)
                }

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryActionButton(title: "Cancel", minWidth: 96, height: 34) {
                        vm.cancelConfirm()
                    }
                    PrimaryActionButton(title: "Clean", minWidth: 96, height: 34) {
                        vm.confirmClean()
                    }
                }
                .padding(.top, 24)
            }
            .padding(26)
            .frame(width: 480)
            .background(Theme.cardBg)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke, lineWidth: 1))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
    }

    // MARK: - 8. EXPLORE DELETE CONFIRM MODAL
    private var confirmExploreDeleteModal: some View {
        ZStack {
            Theme.modalBackdrop.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text(explore.deleteTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Text(explore.deleteDetail)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 10) {
                    RadioOptionRow(
                        selected: !explore.deletePermanent,
                        title: "Move to Trash (recommended)"
                    ) {
                        explore.deletePermanent = false
                    }
                    RadioOptionRow(
                        selected: explore.deletePermanent,
                        title: "Delete permanently"
                    ) {
                        explore.deletePermanent = true
                    }
                }
                .padding(.top, 18)

                if !explore.deletePermanent {
                    Text("You can restore it from the Trash. Disk space is only freed once the Trash is emptied.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 14)
                } else {
                    Text("Permanently deleted files cannot be restored.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.review)
                        .padding(.top, 14)
                }

                Text("Make sure you know what this is. Removing app or system data can stop programs from working. System and Applications folders are protected and cannot be deleted here.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 10)

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryActionButton(title: "Cancel", minWidth: 96, height: 34) {
                        explore.cancelDelete()
                    }
                    PrimaryActionButton(title: "Delete", systemImage: "trash", minWidth: 96, height: 34) {
                        explore.confirmDelete()
                    }
                }
                .padding(.top, 24)
            }
            .padding(26)
            .frame(width: 500)
            .background(Theme.cardBg)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke, lineWidth: 1))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
    }

    // MARK: - 9. DELETING OVERLAY
    private var deletingOverlay: some View {
        ZStack {
            Theme.modalBackdrop.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.3)
                Text(explore.deletingName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Deleting…")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Subviews & Controls

@MainActor
private struct DriveCardView: View {
    @ObservedObject var drive: DriveItem
    let onExplore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CustomCheckBox(checked: $drive.isSelected)

            VStack(alignment: .leading, spacing: 6) {
                Text(drive.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.progressTrack)
                            .frame(height: 5)
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(0, geo.size.width * CGFloat(drive.usedPercent / 100.0)), height: 5)
                    }
                }
                .frame(height: 5)

                Text(drive.usageText)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                drive.toggle()
            }

            SecondaryActionButton(title: "Explore", systemImage: "square.grid.2x2") {
                onExplore()
            }
            .padding(.leading, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.cardBg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
        .cornerRadius(8)
    }
}

@MainActor
private struct CustomFolderCardView: View {
    let folder: String
    let onExplore: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 16))
                .foregroundColor(Theme.textPrimary)

            Text(folder)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            SecondaryActionButton(title: "Explore", systemImage: "square.grid.2x2") {
                onExplore()
            }

            SecondaryIconButton(systemImage: "xmark") {
                onRemove()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.cardBg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
        .cornerRadius(8)
    }
}

@MainActor
private struct CategoryRowView: View {
    @ObservedObject var group: CategoryGroup
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? Theme.textOnAccent : Theme.textPrimary)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.tierColor(group.tier))
                            .frame(width: 8, height: 8)
                        Text("\(group.count) items")
                            .font(.system(size: 12))
                            .foregroundColor(isSelected ? Theme.textOnAccent.opacity(0.8) : Theme.textSecondary)
                    }
                }
                Spacer()
                Text(group.sizeText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.textOnAccent : Theme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.accentSelectedBg : (isHovered ? Theme.hoverFill : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

@MainActor
private struct FindingRowView: View {
    @ObservedObject var item: FindingItem

    var body: some View {
        HStack(spacing: 0) {
            CustomCheckBox(checked: $item.isSelected, disabled: item.isLocked)
                .frame(width: 36, alignment: .leading)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.reason)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.folder)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.trailing, 12)

            Spacer()

            Text(item.sizeText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 90, alignment: .trailing)

            Text(item.modifiedText)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 100, alignment: .center)

            Text(item.tierText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.tierColor(item.tier))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Theme.tierBackground(item.tier))
                .clipShape(Capsule())
                .frame(width: 80, alignment: .center)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(Color.white.opacity(0.001))
        .contextMenu {
            Button("Show in Finder") {
                item.openLocation()
            }
        }
        .help(item.finding.path)
    }
}

@MainActor
private struct ExploreRowView: View {
    @ObservedObject var item: ExploreItem
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                item.navigate()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(item.color)
                            .frame(width: 10, height: 10)
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(item.sizeText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                    }

                    HStack {
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                        Spacer()
                        Text(item.percentText)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.leading, 18)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.progressTrack)
                                .frame(height: 3.5)
                            Capsule()
                                .fill(item.color)
                                .frame(width: max(2, geo.size.width * CGFloat(min(100, item.percent) / 100.0)), height: 3.5)
                        }
                    }
                    .frame(height: 4)
                    .padding(.leading, 18)
                    .padding(.top, 2)
                }
                .padding(.leading, 8)
                .padding(.trailing, 38)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(item.isHot ? Theme.hoverFill : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(item.isHot ? Theme.cardStroke : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if item.showDelete {
                Button {
                    item.delete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(item.canDelete ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.controlBg.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Theme.cardStroke, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!item.canDelete)
                .help(item.deleteTip)
                .padding(.top, 8)
                .padding(.trailing, 6)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                onHoverChanged(true)
            case .ended:
                onHoverChanged(false)
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                item.reveal()
            }
            if item.showDelete {
                Button("Delete…") {
                    item.delete()
                }
                .disabled(!item.canDelete)
            }
        }
    }
}

@MainActor
private struct CustomCheckBox: View {
    @Binding var checked: Bool
    var disabled: Bool = false

    var body: some View {
        Button {
            if !disabled {
                checked.toggle()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(checked ? Theme.accent : Theme.controlBg)
                    .frame(width: 18, height: 18)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(checked ? Theme.accent : Theme.controlStroke, lineWidth: 1.2)
                    .frame(width: 18, height: 18)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textOnAccent)
                }
            }
            .opacity(disabled ? 0.35 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

@MainActor
private struct RadioOptionRow: View {
    let selected: Bool
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.controlBg)
                        .frame(width: 18, height: 18)
                    Circle()
                        .stroke(selected ? Theme.accent : Theme.controlStroke, lineWidth: selected ? 5 : 1.5)
                        .frame(width: 18, height: 18)
                }
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private struct PrimaryActionButton: View {
    let title: String
    var systemImage: String? = nil
    var minWidth: CGFloat = 100
    var height: CGFloat = 34
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(Theme.textOnAccent)
            .frame(minWidth: minWidth, minHeight: height)
            .padding(.horizontal, 14)
            .background(Theme.accent.opacity(disabled ? 0.45 : 1.0))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

@MainActor
private struct SecondaryActionButton: View {
    let title: String
    var systemImage: String? = nil
    var minWidth: CGFloat = 0
    var height: CGFloat = 32
    var disabled: Bool = false
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                }
                Text(title)
                    .font(.system(size: 13))
            }
            .foregroundColor(disabled ? Theme.textTertiary : Theme.textPrimary)
            .frame(minWidth: minWidth, minHeight: height)
            .padding(.horizontal, 12)
            .background(Theme.controlBg.opacity(disabled ? 0.5 : 1.0))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardStroke, lineWidth: 1))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

@MainActor
private struct IconButton: View {
    let systemImage: String
    var disabled: Bool = false
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(disabled ? Theme.textTertiary.opacity(0.45) : Theme.textPrimary)
                .frame(width: 34, height: 30)
                .background(Theme.controlBg.opacity(disabled ? 0.5 : 1.0))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardStroke, lineWidth: 1))
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

@MainActor
private struct SecondaryIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Theme.controlBg)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardStroke, lineWidth: 1))
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
