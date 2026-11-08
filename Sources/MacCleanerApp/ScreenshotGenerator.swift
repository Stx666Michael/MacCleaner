import SwiftUI
import AppKit
import MacCleanerCore

@MainActor
public enum ScreenshotGenerator {
    public static func generateAll(docsDir: String) throws {
        let screenshotsDir = PathUtil.combine(docsDir, "screenshots")
        try FileManager.default.createDirectory(atPath: screenshotsDir, withIntermediateDirectories: true)

        // 1. App Icon (`docs/icon.png`)
        try renderPNG(
            AppIconCanvasView(),
            size: CGSize(width: 512, height: 512),
            scale: 1.0,
            to: PathUtil.combine(docsDir, "icon.png")
        )

        let windowSize = CGSize(width: 1120, height: 760)

        // 2. 01-home.png
        let vmHome = makeDemoViewModel()
        try renderPNG(MainWindowView(vm: vmHome), size: windowSize, scale: 1.0, to: PathUtil.combine(screenshotsDir, "01-home.png"))

        // 3. 02-results.png
        let vmResults = makeDemoViewModel()
        populateDemoResults(vmResults)
        vmResults.state = .results
        try renderPNG(MainWindowView(vm: vmResults), size: windowSize, scale: 1.0, to: PathUtil.combine(screenshotsDir, "02-results.png"))

        // 4. 03-confirm.png
        let vmConfirm = makeDemoViewModel()
        populateDemoResults(vmConfirm)
        vmConfirm.state = .results
        vmConfirm.requestClean()
        try renderPNG(MainWindowView(vm: vmConfirm), size: windowSize, scale: 1.0, to: PathUtil.combine(screenshotsDir, "03-confirm.png"))

        // 5. 04-summary.png
        let vmSummary = makeDemoViewModel()
        let cleanRes = CleanResult(mode: .permanent)
        cleanRes.itemsCleaned = 11
        cleanRes.bytesFreed = Int64(6.25 * 1024 * 1024 * 1024)
        vmSummary.showSummary(cleanRes)
        try renderPNG(MainWindowView(vm: vmSummary), size: windowSize, scale: 1.0, to: PathUtil.combine(screenshotsDir, "04-summary.png"))

        // 6. 05-explore.png
        let vmExplore = makeDemoViewModel()
        let demoRoot = buildDemoFolderTree()
        vmExplore.state = .explore
        vmExplore.explore.root = demoRoot
        vmExplore.explore.title = demoRoot.fullPath
        vmExplore.explore.setCurrent(demoRoot)
        vmExplore.explore.hoverItem = vmExplore.explore.items.first
        try renderPNG(MainWindowView(vm: vmExplore), size: windowSize, scale: 1.0, to: PathUtil.combine(screenshotsDir, "05-explore.png"))

        // 7. 06-explore-drilldown.png
        let vmDrill = makeDemoViewModel()
        let drillRoot = buildDemoFolderTree()
        vmDrill.state = .explore
        vmDrill.explore.root = drillRoot
        vmDrill.explore.title = drillRoot.fullPath
        vmDrill.explore.setCurrent(drillRoot)
        if let projects = drillRoot.children.first(where: { $0.name == "Projects" }) {
            vmDrill.explore.navigateTo(projects)
            vmDrill.explore.hoverItem = vmDrill.explore.items.first
        }
        try renderPNG(MainWindowView(vm: vmDrill), size: windowSize, scale: 1.0, to: PathUtil.combine(screenshotsDir, "06-explore-drilldown.png"))

        // 8. 07-explore-delete.png
        let vmDelete = makeDemoViewModel()
        let delRoot = buildDemoFolderTree()
        vmDelete.state = .explore
        vmDelete.explore.root = delRoot
        vmDelete.explore.title = delRoot.fullPath
        vmDelete.explore.setCurrent(delRoot)
        if let projects = delRoot.children.first(where: { $0.name == "Projects" }) {
            vmDelete.explore.navigateTo(projects)
            if let blogItem = vmDelete.explore.items.first(where: { $0.name == "blog" }) {
                vmDelete.explore.requestDelete(blogItem)
            }
        }
        try renderPNG(MainWindowView(vm: vmDelete), size: windowSize, scale: 1.0, to: PathUtil.combine(screenshotsDir, "07-explore-delete.png"))
    }

    private static func makeDemoViewModel() -> MainViewModel {
        let demoRules = Rules(
            RulesConfig(
                protectedRoots: ["/System", "/Applications", "/Library"],
                knownLocations: [],
                userProfile: "/Users/user",
                downloadsDir: "/Users/user/Downloads"
            )
        )
        let vm = MainViewModel(rules: demoRules)
        vm.drives = [
            DriveItem(
                volume: VolumeInfo(
                    root: "/",
                    name: "Macintosh HD",
                    totalBytes: 931 * 1024 * 1024 * 1024,
                    freeBytes: 394 * 1024 * 1024 * 1024,
                    isSystemVolume: true
                ),
                selected: false
            )
        ]
        vm.customFolders = ["/Users/user/Projects/ExploreDemo"]
        return vm
    }

    private static func populateDemoResults(_ vm: MainViewModel) {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        func d(_ s: String) -> Date { dateFmt.date(from: s) ?? Date() }
        let mb: Int64 = 1024 * 1024

        let findings: [Finding] = [
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/VirtualMachines/ubuntu-dev.utm",
                isDirectory: false,
                size: 1905 * mb,
                modifiedUtc: d("2026-01-10"),
                stampUtc: d("2026-01-10"),
                category: .largeFile,
                tier: .review,
                reason: "Large file, last changed 10 months ago"
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Movies/holiday-trip-2024.mp4",
                isDirectory: false,
                size: 1403 * mb,
                modifiedUtc: d("2026-05-30"),
                stampUtc: d("2026-05-30"),
                category: .largeFile,
                tier: .review,
                reason: "Large file, last changed 5 months ago"
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Movies/screen-recording-march.mov",
                isDirectory: false,
                size: 820 * mb,
                modifiedUtc: d("2026-09-22"),
                stampUtc: d("2026-09-22"),
                category: .largeFile,
                tier: .review,
                reason: "Large file, last changed 45 days ago"
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Downloads/macos-sequoia-installer.dmg",
                isDirectory: false,
                size: 640 * mb,
                modifiedUtc: d("2026-04-10"),
                stampUtc: d("2026-04-10"),
                category: .largeFile,
                tier: .review,
                reason: "Large file, last changed 7 months ago"
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Apps/PhotoEditor/crash-0412.ips",
                isDirectory: false,
                size: 380 * mb,
                modifiedUtc: d("2026-10-17"),
                stampUtc: d("2026-10-17"),
                category: .crashData,
                tier: .review,
                reason: "Crash dump file"
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Projects/blog/node_modules",
                isDirectory: true,
                size: 250 * mb,
                modifiedUtc: d("2026-03-31"),
                stampUtc: d("2026-03-31"),
                category: .nodeModules,
                tier: .review,
                reason: "Project dependencies, no changes for 7 months. Restore with npm install."
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Projects/dashboard/node_modules",
                isDirectory: true,
                size: 250 * mb,
                modifiedUtc: d("2026-03-31"),
                stampUtc: d("2026-03-31"),
                category: .nodeModules,
                tier: .review,
                reason: "Project dependencies, no changes for 7 months. Restore with npm install."
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Projects/storefront/node_modules",
                isDirectory: true,
                size: 250 * mb,
                modifiedUtc: d("2026-03-31"),
                stampUtc: d("2026-03-31"),
                category: .nodeModules,
                tier: .review,
                reason: "Project dependencies, no changes for 7 months. Restore with npm install."
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Apps/Renderer/crash-0319.ips",
                isDirectory: false,
                size: 210 * mb,
                modifiedUtc: d("2026-09-12"),
                stampUtc: d("2026-09-12"),
                category: .crashData,
                tier: .review,
                reason: "Crash dump file"
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Logs/worker-2026-02.log",
                isDirectory: false,
                size: 165 * mb,
                modifiedUtc: d("2026-02-14"),
                stampUtc: d("2026-02-14"),
                category: .oldLogs,
                tier: .review,
                reason: "Log file, not modified for 8 months"
            ),
            Finding(
                path: "/Users/user/Projects/MacCleanerDemo/Logs/indexer-2026-01.log",
                isDirectory: false,
                size: 140 * mb,
                modifiedUtc: d("2026-01-20"),
                stampUtc: d("2026-01-20"),
                category: .oldLogs,
                tier: .review,
                reason: "Log file, not modified for 9 months"
            )
        ]

        let totalBytes = findings.reduce(Int64(0)) { $0 + $1.size }
        let res = ScanResult(
            findings: findings,
            deniedFolders: 0,
            filesScanned: 17,
            bytesScanned: totalBytes,
            elapsed: 0.2,
            cancelled: false
        )
        vm.loadResults(res)
        vm.selectVisible()
    }

    private static func buildDemoFolderTree() -> FolderNode {
        let mb: Int64 = 1024 * 1024
        let root = FolderNode(name: "/Users/user/Projects/ExploreDemo", parent: nil)

        func makeFolder(_ name: String, parent: FolderNode, size: Int64, files: Int64) -> FolderNode {
            let n = FolderNode(name: name, parent: parent)
            n.size = size
            n.ownFilesSize = size
            n.fileCount = files
            n.ownFileCount = Int(files)
            parent.children.append(n)
            return n
        }

        _ = makeFolder("Games", parent: root, size: Int64(4.07 * 1024) * mb, files: 8)
        _ = makeFolder("Movies", parent: root, size: Int64(3.00 * 1024) * mb, files: 8)

        let projects = FolderNode(name: "Projects", parent: root)
        _ = makeFolder("ml-experiments", parent: projects, size: Int64(1.66 * 1024) * mb, files: 2)
        _ = makeFolder("webshop", parent: projects, size: 494 * mb, files: 5)
        _ = makeFolder("blog", parent: projects, size: 350 * mb, files: 1)
        projects.size = projects.children.reduce(0) { $0 + $1.size }
        projects.fileCount = projects.children.reduce(0) { $0 + $1.fileCount }
        root.children.append(projects)

        _ = makeFolder("Photos", parent: root, size: 837 * mb, files: 85)
        _ = makeFolder("Downloads", parent: root, size: 770 * mb, files: 2)
        _ = makeFolder("Documents", parent: root, size: 201 * mb, files: 15)

        root.children.sort { $0.size > $1.size }
        root.size = root.children.reduce(0) { $0 + $1.size }
        root.fileCount = root.children.reduce(0) { $0 + $1.fileCount }
        return root
    }

    private static func renderPNG<V: View>(_ view: V, size: CGSize, scale: CGFloat, to path: String) throws {
        let framed = view
            .environment(\.isScreenshotMode, true)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else {
            throw NSError(domain: "ScreenshotGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render CGImage for \(path)"])
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ScreenshotGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG for \(path)"])
        }
        try pngData.write(to: URL(fileURLWithPath: path))
    }
}

private struct AppIconCanvasView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 112, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0x39 / 255.0, green: 0x7E / 255.0, blue: 0xB9 / 255.0),
                            Color(red: 0x2D / 255.0, green: 0x8F / 255.0, blue: 0x8B / 255.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 112, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 6)
                )
                .padding(16)

            // Treemap blocks
            HStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 156, height: 292)

                VStack(spacing: 20) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.white.opacity(0.78))
                        .frame(width: 126, height: 152)

                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 62, height: 120)

                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.42))
                            .frame(width: 48, height: 120)
                    }
                }
            }

            // Sparkle star in top-right
            FourPointStar()
                .fill(Color(red: 1.0, green: 0.85, blue: 0.36))
                .frame(width: 118, height: 118)
                .shadow(color: .black.opacity(0.22), radius: 6, x: 2, y: 4)
                .offset(x: 102, y: -96)
        }
        .frame(width: 512, height: 512)
    }
}

private struct FourPointStar: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let outerX = rect.width / 2
        let outerY = rect.height / 2
        let inner = rect.width * 0.14

        var p = Path()
        p.move(to: CGPoint(x: cx, y: cy - outerY))
        p.addLine(to: CGPoint(x: cx + inner, y: cy - inner))
        p.addLine(to: CGPoint(x: cx + outerX, y: cy))
        p.addLine(to: CGPoint(x: cx + inner, y: cy + inner))
        p.addLine(to: CGPoint(x: cx, y: cy + outerY))
        p.addLine(to: CGPoint(x: cx - inner, y: cy + inner))
        p.addLine(to: CGPoint(x: cx - outerX, y: cy))
        p.addLine(to: CGPoint(x: cx - inner, y: cy - inner))
        p.closeSubpath()
        return p
    }
}
