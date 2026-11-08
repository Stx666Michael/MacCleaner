import XCTest
import Darwin
@testable import MacCleanerCore

final class CleanerTests: XCTestCase {
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

    func testPermanentDeleteRemovesFileAndReportsFreedBytes() {
        let p = sb.file(PathUtil.combine(sb.me, "Movies/big.mkv"), bytes: 5000)
        let result = sb.newCleaner().clean([Sandbox.make(p, size: 5000)], mode: .permanent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(result.bytesFreed, 5000)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testFileChangedAfterScanIsSkipped() throws {
        let p = sb.file(PathUtil.combine(sb.me, "doc.bin"), bytes: 5000)
        let finding = Sandbox.make(p, size: 5000)
        if let handle = FileHandle(forWritingAtPath: p) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("edited after the scan".utf8))
            try handle.close()
        }

        let result = sb.newCleaner().clean([finding], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].reason.contains("Changed"))
    }

    func testProtectedFileIsRefusedEvenIfFindingClaimsItIsSafe() {
        let p = sb.file(PathUtil.combine(sb.system, "Library/core.dylib"), bytes: 100)
        let forged = Sandbox.make(p, size: 100, tier: .safe)

        let result = sb.newCleaner().clean([forged], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        XCTAssertEqual(result.failures.count, 1)
    }

    func testLockedTierIsRefused() {
        let p = sb.file(PathUtil.combine(sb.me, "x.bin"), bytes: 100)
        let result = sb.newCleaner().clean([Sandbox.make(p, size: 100, tier: .locked)], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        XCTAssertEqual(result.failures.count, 1)
    }

    func testAnotherUsersFileIsRefused() {
        let p = sb.file(PathUtil.combine(sb.other, "private.docx"), bytes: 100)
        let result = sb.newCleaner().clean([Sandbox.make(p, size: 100)], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        XCTAssertEqual(result.failures.count, 1)
    }

    func testApprovedFolderItselfCannotBeDeletedWithoutContentsOnly() {
        sb.file(PathUtil.combine(sb.sysTemp, "a.tmp"), bytes: 100)
        let f = Sandbox.make(sb.sysTemp, size: 100, cat: .temp, tier: .safe, isDir: true)

        let result = sb.newCleaner().clean([f], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.sysTemp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PathUtil.combine(sb.sysTemp, "a.tmp")))
        XCTAssertEqual(result.failures.count, 1)
    }

    func testApprovedCacheFolderItselfCannotBeDeletedOnlyItsContents() {
        sb.file(PathUtil.combine(sb.cache, "a.bin"), bytes: 100)
        let f = Sandbox.make(sb.cache, size: 100, cat: .largeFile, tier: .review, isDir: true, contentsOnly: false)

        let result = sb.newCleaner().clean([f], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.cache))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PathUtil.combine(sb.cache, "a.bin")))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].reason.contains("only its contents"))
        XCTAssertNotNil(sb.rules.getDeleteBlockReason(sb.cache))
        XCTAssertNil(sb.rules.getDeleteBlockReason(PathUtil.combine(sb.cache, "a.bin")))
    }

    func testWholeUserFolderCanBeDeletedWithFreshStampButNeverProfileItself() {
        let dir = PathUtil.combine(sb.me, "Projects/old")
        sb.file(PathUtil.combine(dir, "sub/x.bin"), bytes: 500)
        sb.file(PathUtil.combine(dir, "y.bin"), bytes: 500)
        let f = Sandbox.make(dir, size: 1000, cat: .largeFile, tier: .review, isDir: true)

        let result = sb.newCleaner().clean([f], mode: .permanent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
        XCTAssertEqual(result.bytesFreed, 1000)

        let profile = Sandbox.make(sb.me, size: 1, cat: .largeFile, tier: .review, isDir: true)
        let blocked = sb.newCleaner().clean([profile], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.me))
        XCTAssertEqual(blocked.failures.count, 1)
    }

    func testContentsOnlyEmptiesCacheButKeepsFolder() throws {
        sb.file(PathUtil.combine(sb.cache, "a.bin"), bytes: 1000)
        sb.file(PathUtil.combine(sb.cache, "sub/b.bin"), bytes: 1000)
        let f = Sandbox.make(sb.cache, size: 2000, cat: .appCache, tier: .safe, isDir: true, contentsOnly: true)

        let result = sb.newCleaner().clean([f], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.cache))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: sb.cache)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(result.bytesFreed, 2000)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testContentsOnlyIsRefusedForFolderThatIsNotApprovedCache() {
        let dir = PathUtil.combine(sb.me, "Documents")
        sb.file(PathUtil.combine(dir, "thesis.docx"), bytes: 100)
        let f = Sandbox.make(dir, size: 100, cat: .appCache, tier: .safe, isDir: true, contentsOnly: true)

        let result = sb.newCleaner().clean([f], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: PathUtil.combine(dir, "thesis.docx")))
        XCTAssertEqual(result.failures.count, 1)
    }

    func testDeletingFolderNeverFollowsSymlinkInsideIt() {
        let precious = sb.file(PathUtil.combine(sb.outside, "precious.bin"), bytes: 1000)
        sb.file(PathUtil.combine(sb.cache, "junk.bin"), bytes: 1000)
        let link = sb.symlink(PathUtil.combine(sb.cache, "link"), target: sb.outside)
        let f = Sandbox.make(sb.cache, size: 1000, cat: .appCache, tier: .safe, isDir: true, contentsOnly: true)

        _ = sb.newCleaner().clean([f], mode: .permanent)

        XCTAssertTrue(FileManager.default.fileExists(atPath: precious), "file behind the symlink must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sb.outside))
        var st = stat()
        XCTAssertNotEqual(lstat(link, &st), 0, "the symlink itself is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PathUtil.combine(sb.cache, "junk.bin")))
    }

    func testPathThatGoesThroughSymlinkIsRefused() {
        let victim = sb.file(PathUtil.combine(sb.system, "keep.dylib"), bytes: 100)
        sb.symlink(PathUtil.combine(sb.me, "sneaky"), target: sb.system)
        let viaLink = PathUtil.combine(sb.me, "sneaky/keep.dylib")
        var st = stat()
        lstat(victim, &st)
        let mod = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
        let f = Finding(
            path: viaLink,
            isDirectory: false,
            size: 100,
            modifiedUtc: mod,
            stampUtc: mod,
            category: .largeFile,
            tier: .review,
            reason: "forged"
        )

        let result = sb.newCleaner().clean([f], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim))
        XCTAssertEqual(result.failures.count, 1)
    }

    func testMissingFileAndUnreadablePathDoNotCrashRun() {
        let gone = PathUtil.combine(sb.me, "gone.bin")
        let ok = sb.file(PathUtil.combine(sb.me, "ok.bin"), bytes: 100)
        let now = Date()
        let items = [
            Finding(path: gone, isDirectory: false, size: 1, modifiedUtc: now, stampUtc: now, category: .largeFile, tier: .review, reason: "t"),
            Finding(path: "//server/share/x", isDirectory: false, size: 1, modifiedUtc: now, stampUtc: now, category: .largeFile, tier: .review, reason: "t"),
            Sandbox.make(ok, size: 100)
        ]
        let result = sb.newCleaner().clean(items, mode: .permanent)
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ok))
    }

    func testReadOnlyFilesAreDeleted() {
        let p = sb.file(PathUtil.combine(sb.me, "ro.bin"), bytes: 100)
        chmod(p, S_IRUSR)
        let result = sb.newCleaner().clean([Sandbox.make(p, size: 100)], mode: .permanent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testUserImmutableFlaggedFilesAreUnlockedAndDeleted() {
        let p = sb.file(PathUtil.combine(sb.me, "locked-flag.bin"), bytes: 100)
        chflags(p, UInt32(UF_IMMUTABLE))
        let result = sb.newCleaner().clean([Sandbox.make(p, size: 100)], mode: .permanent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testEveryOutcomeIsWrittenToLog() throws {
        let p = sb.file(PathUtil.combine(sb.me, "logged.bin"), bytes: 100)
        let blocked = sb.file(PathUtil.combine(sb.system, "blocked.dylib"), bytes: 100)
        let result = sb.newCleaner().clean([Sandbox.make(p, size: 100), Sandbox.make(blocked, size: 100)], mode: .permanent)

        let log = try String(contentsOfFile: result.logPath!, encoding: .utf8)
        XCTAssertTrue(log.contains("DELETE"))
        XCTAssertTrue(log.contains("logged.bin"))
        XCTAssertTrue(log.contains("SKIP"))
        XCTAssertTrue(log.contains("blocked.dylib"))
    }

    func testScanThenCleanRoundTripRemovesOnlySelectedItem() async {
        let a = sb.file(PathUtil.combine(sb.me, "a.bin"), bytes: 5000)
        let b = sb.file(PathUtil.combine(sb.me, "b.bin"), bytes: 5000)
        let r = await MacCleanerCore.Scanner(sb.rules).scanAsync(ScanOptions(roots: [sb.root], largeFileThreshold: 1000))

        let picked = r.findings.filter { $0.path == a }
        let result = sb.newCleaner().clean(picked, mode: .permanent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b))
        XCTAssertEqual(result.bytesFreed, 5000)
    }
}
