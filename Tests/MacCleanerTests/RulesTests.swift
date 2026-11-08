import XCTest
@testable import MacCleanerCore

final class RulesTests: XCTestCase {
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

    private func lock(_ path: String) -> String? {
        sb.rules.getLockReason(path)
    }

    func testProtectedFolderContentsAreLocked() {
        XCTAssertNotNil(lock(PathUtil.combine(sb.system, "Library/CoreServices/Finder.app")))
        XCTAssertNotNil(lock(sb.system))
    }

    func testCasingDoesNotBypassProtection() {
        XCTAssertNotNil(lock(PathUtil.combine(sb.root, "SYSTEM/library/x.dylib")))
        XCTAssertNotNil(lock(PathUtil.combine(sb.root, "system/x.dylib")))
    }

    func testDotDotSegmentsAreResolvedBeforeChecking() {
        let sneaky = sb.me + "/../../System/x.dylib"
        XCTAssertNotNil(lock(sneaky))
    }

    func testOtherUsersAndUserRootAreLocked() {
        XCTAssertNotNil(lock(PathUtil.combine(sb.other, "secret.docx")))
        let usersDir = (sb.me as NSString).deletingLastPathComponent
        XCTAssertNotNil(lock(usersDir))
        XCTAssertNotNil(lock(sb.me))
    }

    func testOwnFilesAreAllowed() {
        XCTAssertNil(lock(PathUtil.combine(sb.me, "Movies/big.mkv")))
        XCTAssertNil(lock(PathUtil.combine(sb.downloads, "installer.dmg")))
    }

    func testSystemFilesAreLockedAnywhere() {
        for name in ["sleepimage", "swapfile0", "swapfile1", "kernel", "pagefile.sys", "ntuser.dat"] {
            XCTAssertNotNil(lock(PathUtil.combine(sb.root, name)), "Expected \(name) at root to be locked")
            XCTAssertNotNil(lock(PathUtil.combine(sb.me, name)), "Expected \(name) in profile to be locked")
        }
    }

    func testUnsafePathShapesAreLocked() {
        XCTAssertNotNil(lock("\\\\server\\share\\file.bin"))
        XCTAssertNotNil(lock("//server/share/file.bin"))
        XCTAssertNotNil(lock("relative/file.txt"))
        XCTAssertNotNil(lock(""))
        XCTAssertNotNil(lock("/"))
        XCTAssertNotNil(lock("/Volumes"))
        XCTAssertNotNil(lock("/Volumes/ExternalDisk"))
    }

    func testApprovedLocationInsideProtectedFolderIsAllowedButNotFolderItself() {
        XCTAssertNil(lock(PathUtil.combine(sb.sysTemp, "junk.tmp")))
        XCTAssertNotNil(lock(sb.sysTemp))
        XCTAssertNotNil(lock(PathUtil.combine(sb.system, "Other/junk.tmp")))
    }

    func testDefaultRulesProtectRealSystemFolders() {
        let rules = Rules.createDefault()
        XCTAssertNotNil(rules.getLockReason("/System/Library/Kernels/kernel"))
        XCTAssertNotNil(rules.getLockReason("/Applications"))
        XCTAssertNotNil(rules.getLockReason("/private/var/vm/sleepimage"))
        XCTAssertNil(rules.getLockReason(PathUtil.combine(NSTemporaryDirectory(), "x.tmp")))
    }

    func testMacOSSystemSymlinksAndFirmlinksAreCanonicalized() throws {
        XCTAssertEqual(try PathUtil.normalize("/var/folders/xx/tmp"), "/private/var/folders/xx/tmp")
        XCTAssertEqual(try PathUtil.normalize("/tmp/test.txt"), "/private/tmp/test.txt")
        XCTAssertEqual(try PathUtil.normalize("/etc/hosts"), "/private/etc/hosts")
        XCTAssertEqual(try PathUtil.normalize("/System/Volumes/Data/Users/me/file.txt"), "/Users/me/file.txt")
        XCTAssertEqual(try PathUtil.normalize("/System/Volumes/Data/Applications/Safari.app"), "/Applications/Safari.app")
    }

    func testFormatSizeAndAgeMatchConventions() {
        XCTAssertEqual(Format.size(0), "0 B")
        XCTAssertEqual(Format.size(512), "512 B")
        XCTAssertEqual(Format.size(1024), "1.00 KB")
        XCTAssertEqual(Format.size(15 * 1024 * 1024), "15.0 MB")
        XCTAssertEqual(Format.size(250 * 1024 * 1024), "250 MB")
        XCTAssertEqual(Format.age(3600), "less than 2 hours")
        XCTAssertEqual(Format.age(5 * 3600), "5 hours")
        XCTAssertEqual(Format.age(10 * 86400), "10 days")
        XCTAssertEqual(Format.age(90 * 86400), "3 months")
        XCTAssertEqual(Format.age(800 * 86400), "2 years")
    }
}
