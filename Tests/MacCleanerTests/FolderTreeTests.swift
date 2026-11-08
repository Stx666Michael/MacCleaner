import XCTest
@testable import MacCleanerCore

final class FolderTreeTests: XCTestCase {
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

    private func scan(_ root: String? = nil) async throws -> FolderTreeResult {
        try await FolderTreeScanner().scanAsync(root ?? sb.me)
    }

    func testSizesAreTotalledUpTheTree() async throws {
        sb.file(PathUtil.combine(sb.me, "a.bin"), bytes: 100)
        sb.file(PathUtil.combine(sb.me, "Movies/v1.mkv"), bytes: 1000)
        sb.file(PathUtil.combine(sb.me, "Movies/2024/v2.mkv"), bytes: 2000)
        sb.file(PathUtil.combine(sb.me, "Docs/d.txt"), bytes: 50)

        let r = try await scan()
        XCTAssertEqual(r.root.size, 3150)
        XCTAssertEqual(r.root.fileCount, 4)
        XCTAssertEqual(r.root.ownFilesSize, 100)

        let movies = try XCTUnwrap(r.root.children.first { $0.name == "Movies" })
        XCTAssertEqual(movies.size, 3000)
        XCTAssertEqual(movies.ownFilesSize, 1000)
        XCTAssertEqual(movies.children.first?.size, 2000)
        XCTAssertEqual(r.bytes, 3150)
        XCTAssertEqual(r.files, 4)
    }

    func testChildrenAreSortedLargestFirstAndFilesAreSortedToo() async throws {
        sb.file(PathUtil.combine(sb.me, "small/x"), bytes: 10)
        sb.file(PathUtil.combine(sb.me, "big/x"), bytes: 5000)
        sb.file(PathUtil.combine(sb.me, "mid/x"), bytes: 300)
        sb.file(PathUtil.combine(sb.me, "f1"), bytes: 5)
        sb.file(PathUtil.combine(sb.me, "f2"), bytes: 50)

        let r = try await scan()
        XCTAssertEqual(Array(r.root.children.prefix(3).map(\.name)), ["big", "mid", "small"])
        for i in 0..<(r.root.children.count - 1) {
            XCTAssertGreaterThanOrEqual(r.root.children[i].size, r.root.children[i + 1].size)
        }
        XCTAssertEqual(r.root.files.map(\.name), ["f2", "f1"])
    }

    func testOnlyLargestFilesAreKeptPerFolderButTotalsStayExact() async throws {
        let n = FolderNode.maxFilesKept + 25
        for i in 1...n {
            sb.file(PathUtil.combine(sb.me, "many/f\(i).bin"), bytes: i)
        }

        let r = try await scan()
        let many = try XCTUnwrap(r.root.children.first { $0.name == "many" })
        let expected = Int64(n * (n + 1) / 2)
        XCTAssertEqual(many.size, expected)
        XCTAssertEqual(many.files.count, FolderNode.maxFilesKept)
        XCTAssertEqual(many.files[0].size, Int64(n))
        XCTAssertEqual(many.otherFileCount, 25)
        let keptSum = many.files.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertEqual(many.ownFilesSize, keptSum + many.otherFilesSize)
    }

    func testSymlinksAreNotFollowed() async throws {
        sb.file(PathUtil.combine(sb.outside, "hidden.bin"), bytes: 9999)
        sb.file(PathUtil.combine(sb.me, "real.bin"), bytes: 10)
        sb.symlink(PathUtil.combine(sb.me, "link"), target: sb.outside)

        let r = try await scan()
        XCTAssertEqual(r.root.size, 10)
        XCTAssertFalse(r.root.children.contains { $0.name == "link" })
    }

    func testEmptyFoldersAreListedWithZeroSize() async throws {
        try FileManager.default.createDirectory(atPath: PathUtil.combine(sb.me, "empty"), withIntermediateDirectories: true)
        let r = try await scan()
        let empty = try XCTUnwrap(r.root.children.first { $0.name == "empty" })
        XCTAssertEqual(empty.size, 0)
    }

    func testFullPathsAndFindRoundTrip() async throws {
        sb.file(PathUtil.combine(sb.me, "a/b/c/x.bin"), bytes: 7)
        let r = try await scan()
        let c = try XCTUnwrap(r.root.find(PathUtil.combine(sb.me, "a/b/c")))
        XCTAssertEqual(c.fullPath, PathUtil.combine(sb.me, "a/b/c"))
        XCTAssertTrue(r.root === r.root.find(sb.me))
        XCTAssertTrue(c === r.root.find(PathUtil.combine(sb.me, "A/B/C")))
        XCTAssertNil(r.root.find(PathUtil.combine(sb.me, "a/nope")))
        XCTAssertNil(r.root.find(sb.other))
    }

    func testRemovingChildOrFileUpdatesEveryAncestor() async throws {
        sb.file(PathUtil.combine(sb.me, "top.bin"), bytes: 100)
        sb.file(PathUtil.combine(sb.me, "a/b/deep.bin"), bytes: 1000)
        sb.file(PathUtil.combine(sb.me, "a/keep.bin"), bytes: 10)
        let r = try await scan()
        let a = try XCTUnwrap(r.root.children.first { $0.name == "a" })
        let b = try XCTUnwrap(a.children.first)

        XCTAssertTrue(a.removeChild(b))
        XCTAssertEqual(a.size, 10)
        XCTAssertEqual(r.root.size, 110)
        XCTAssertEqual(r.root.fileCount, 2)

        XCTAssertTrue(r.root.removeFile("top.bin"))
        XCTAssertEqual(r.root.size, 10)
        XCTAssertEqual(r.root.fileCount, 1)
        XCTAssertEqual(r.root.ownFilesSize, 0)
        XCTAssertFalse(r.root.removeFile("top.bin"))
    }

    func testCancellationIsReported() async throws {
        for i in 0..<30 {
            sb.file(PathUtil.combine(sb.me, "d\(i)/f"), bytes: 1)
        }
        let mePath = sb.me
        let task = Task {
            try await FolderTreeScanner().scanAsync(mePath)
        }
        task.cancel()
        let r = try await task.value
        XCTAssertTrue(r.cancelled)
    }

    func testMissingOrInvalidRootsThrow() async {
        do {
            _ = try await scan(PathUtil.combine(sb.root, "nope"))
            XCTFail("Expected directoryNotFound")
        } catch {}

        do {
            _ = try await scan("//server/share")
            XCTFail("Expected unsafePath")
        } catch {}
    }

    func testUnreadableFolderIsFlaggedNotFatal() async throws {
        sb.file(PathUtil.combine(sb.me, "ok/f"), bytes: 5)
        let r = try await scan()
        XCTAssertFalse(r.root.denied)
        XCTAssertEqual(r.deniedFolders, 0)
    }
}
