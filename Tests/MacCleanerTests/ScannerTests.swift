import XCTest
@testable import MacCleanerCore

final class ScannerTests: XCTestCase {
    private var sb: Sandbox!

    override func setUp() {
        super.setUp()
        sb = Sandbox()
    }

    override func tearDown() {
        sb.dispose()
        sb = nil
        super.tearDown()
    }

    private func scan(threshold: Int64 = 1000, roots: [String] = []) async -> ScanResult {
        let scanner = MacCleanerCore.Scanner(sb.rules)
        let targetRoots = roots.isEmpty ? [sb.root] : roots
        return await scanner.scanAsync(ScanOptions(roots: targetRoots, largeFileThreshold: threshold))
    }

    func testFindsLargeFilesAndIgnoresSmallOnes() async {
        let big = sb.file(PathUtil.combine(sb.me, "Movies/big.mkv"), bytes: 5000)
        sb.file(PathUtil.combine(sb.me, "Movies/small.txt"), bytes: 100)

        let r = await scan()
        let matches = r.findings.filter { $0.path == big }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].category, .largeFile)
        XCTAssertEqual(matches[0].tier, .review)
        XCTAssertFalse(r.findings.contains { $0.path.hasSuffix("small.txt") })
    }

    func testLargeFilesInProtectedOrForeignPlacesAreListedAsLocked() async {
        let sys = sb.file(PathUtil.combine(sb.system, "Library/huge.dylib"), bytes: 5000)
        let theirs = sb.file(PathUtil.combine(sb.other, "movie.mp4"), bytes: 5000)

        let r = await scan()
        XCTAssertEqual(r.findings.first(where: { $0.path == sys })?.tier, .locked)
        XCTAssertEqual(r.findings.first(where: { $0.path == theirs })?.tier, .locked)
    }

    func testDoesNotFollowSymlinks() async {
        sb.file(PathUtil.combine(sb.outside, "hidden-big.bin"), bytes: 5000)
        sb.symlink(PathUtil.combine(sb.me, "link"), target: sb.outside)

        let r = await scan(threshold: 1000, roots: [sb.me])
        XCTAssertFalse(r.findings.contains { $0.path.contains("hidden-big") })
        XCTAssertFalse(r.findings.contains { $0.path.contains("link") })
    }

    func testOldNodeModulesIsOneItemAndRecentIsIgnored() async {
        let old = PathUtil.combine(sb.me, "oldproj/node_modules")
        sb.file(PathUtil.combine(old, "a/index.js"), bytes: 3000, ageDays: 200)
        sb.file(PathUtil.combine(old, "b/index.js"), bytes: 3000, ageDays: 200)
        sb.setMtime(old, date: Date().addingTimeInterval(-200 * 86400))

        let fresh = PathUtil.combine(sb.me, "newproj/node_modules")
        sb.file(PathUtil.combine(fresh, "a/index.js"), bytes: 3000)

        let r = await scan()
        let nms = r.findings.filter { $0.category == .nodeModules }
        XCTAssertEqual(nms.count, 1)
        XCTAssertEqual(nms[0].path, old)
        XCTAssertTrue(nms[0].isDirectory)
        XCTAssertEqual(nms[0].size, 6000)
        XCTAssertFalse(r.findings.contains { $0.category == .largeFile && $0.path.contains("node_modules") })
    }

    func testApprovedCacheIsOneContentsOnlyItem() async {
        sb.file(PathUtil.combine(sb.cache, "a.bin"), bytes: 4000)
        sb.file(PathUtil.combine(sb.cache, "sub/b.bin"), bytes: 4000)

        let r = await scan()
        let caches = r.findings.filter { $0.category == .appCache }
        XCTAssertEqual(caches.count, 1)
        XCTAssertEqual(caches[0].path, sb.cache)
        XCTAssertTrue(caches[0].contentsOnly)
        XCTAssertEqual(caches[0].tier, .safe)
        XCTAssertEqual(caches[0].size, 8000)
        XCTAssertFalse(r.findings.contains { $0.category == .largeFile && $0.path.hasPrefix(sb.cache) })
    }

    func testTempItemsAreListedPerChildAndOnlyWhenOldEnough() async {
        let old = sb.file(PathUtil.combine(sb.sysTemp, "old.tmp"), bytes: 50, ageDays: 3)
        sb.file(PathUtil.combine(sb.sysTemp, "new.tmp"), bytes: 50)

        let r = await scan()
        let temps = r.findings.filter { $0.category == .temp }
        XCTAssertEqual(temps.count, 1)
        XCTAssertEqual(temps[0].path, old)
        XCTAssertEqual(temps[0].tier, .safe)
    }

    func testOldInstallersInDownloadsAreFoundButRecentOnesAreNot() async {
        let old = sb.file(PathUtil.combine(sb.downloads, "app.dmg"), bytes: 200, ageDays: 200)
        sb.file(PathUtil.combine(sb.downloads, "new-app.dmg"), bytes: 200)
        sb.file(PathUtil.combine(sb.me, "Documents/tool.dmg"), bytes: 200, ageDays: 200)

        let r = await scan()
        let dls = r.findings.filter { $0.category == .oldDownloads }
        XCTAssertEqual(dls.count, 1)
        XCTAssertEqual(dls[0].path, old)
    }

    func testOldBigLogsAndCrashDumpsAreFound() async {
        let log = sb.file(PathUtil.combine(sb.me, "app/service.log"), bytes: 2 * 1024 * 1024, ageDays: 60)
        let dump = sb.file(PathUtil.combine(sb.me, "app/crash.ips"), bytes: 2 * 1024 * 1024)
        sb.file(PathUtil.combine(sb.me, "app/recent.log"), bytes: 2 * 1024 * 1024)
        sb.file(PathUtil.combine(sb.me, "app/tiny.log"), bytes: 100, ageDays: 60)

        let r = await scan(threshold: Int64.max)
        XCTAssertEqual(r.findings.first(where: { $0.path == log })?.category, .oldLogs)
        XCTAssertEqual(r.findings.first(where: { $0.path == dump })?.category, .crashData)
        XCTAssertEqual(r.findings.count, 2)
    }

    func testCancellationStopsTheScan() async {
        for i in 0..<50 {
            sb.file(PathUtil.combine(sb.me, "d\(i)/f.bin"), bytes: 10)
        }
        let task = Task {
            await MacCleanerCore.Scanner(sb.rules).scanAsync(ScanOptions(roots: [sb.root]))
        }
        task.cancel()
        let r = await task.value
        XCTAssertTrue(r.cancelled)
    }

    func testScanProgressReportsFilesScanned() async {
        for i in 0..<20 {
            sb.file(PathUtil.combine(sb.cache, "dir\(i)/item.bin"), bytes: 100)
            sb.file(PathUtil.combine(sb.me, "dir\(i)/file.bin"), bytes: 200)
        }

        final class ProgressRecorder: @unchecked Sendable {
            private let lock = NSLock()
            var snapshots: [ScanProgress] = []
            func record(_ p: ScanProgress) {
                lock.lock()
                snapshots.append(p)
                lock.unlock()
            }
        }

        let recorder = ProgressRecorder()
        let r = await MacCleanerCore.Scanner(sb.rules).scanAsync(ScanOptions(roots: [sb.root])) { p in
            recorder.record(p)
        }

        XCTAssertEqual(r.filesScanned, 40)
        XCTAssertFalse(recorder.snapshots.isEmpty)
        XCTAssertEqual(recorder.snapshots.last?.filesScanned, 40)
        XCTAssertEqual(recorder.snapshots.last?.bytesScanned, 6000)
    }
}
