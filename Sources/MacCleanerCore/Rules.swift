import Foundation

/// A folder that is known to hold disposable data.
/// - `perChild`: true: each entry inside is its own finding. false: the whole folder is one finding and only its contents are cleaned.
public struct KnownLocation: Sendable, Equatable {
    public let path: String
    public let category: Category
    public let label: String
    public let perChild: Bool
    public let minAge: TimeInterval?
    public let needsAdmin: Bool

    public init(
        path: String,
        category: Category,
        label: String,
        perChild: Bool,
        minAge: TimeInterval? = nil,
        needsAdmin: Bool = false
    ) {
        self.path = path
        self.category = category
        self.label = label
        self.perChild = perChild
        self.minAge = minAge
        self.needsAdmin = needsAdmin
    }
}

public struct RulesConfig: Sendable {
    public let protectedRoots: [String]
    public let knownLocations: [KnownLocation]
    public let userProfile: String
    public let downloadsDir: String?

    public init(
        protectedRoots: [String],
        knownLocations: [KnownLocation],
        userProfile: String,
        downloadsDir: String?
    ) {
        self.protectedRoots = protectedRoots
        self.knownLocations = knownLocations
        self.userProfile = userProfile
        self.downloadsDir = downloadsDir
    }
}

/// Decides what may never be cleaned. This is the single source of truth used by both the scanner
/// (to mark items Locked) and the cleaner (to refuse to delete them).
public final class Rules: Sendable {
    public static let tempMinAge: TimeInterval = 24 * 3600
    public static let logMinAge: TimeInterval = 30 * 86400
    public static let downloadMinAge: TimeInterval = 90 * 86400
    public static let nodeModulesMinAge: TimeInterval = 90 * 86400
    public static let minRuleFileSize: Int64 = 1024 * 1024

    private static let protectedFileNames: Set<String> = [
        "sleepimage",
        "swapfile0",
        "swapfile1",
        "swapfile2",
        "kernel",
        "boot.efi",
        "com.apple.boot.plist",
        "pagefile.sys",
        "hiberfil.sys",
        "swapfile.sys"
    ]

    private let _protectedRoots: [String]
    private let _known: [KnownLocation]
    private let _userProfile: String
    private let _usersRoot: String
    public let downloadsDir: String?

    public var knownLocations: [KnownLocation] { _known }
    public var userProfile: String { _userProfile }

    public init(_ config: RulesConfig) {
        var seenRoots = Set<String>()
        var roots: [String] = []
        for r in config.protectedRoots {
            if let norm = Self.tryNormalize(r), seenRoots.insert(norm.lowercased()).inserted {
                roots.append(norm)
            }
        }
        self._protectedRoots = roots

        var knownList: [KnownLocation] = []
        for k in config.knownLocations {
            if let norm = Self.tryNormalize(k.path) {
                knownList.append(
                    KnownLocation(
                        path: norm,
                        category: k.category,
                        label: k.label,
                        perChild: k.perChild,
                        minAge: k.minAge,
                        needsAdmin: k.needsAdmin
                    )
                )
            }
        }
        self._known = knownList

        let normProfile = (try? PathUtil.normalize(config.userProfile)) ?? config.userProfile
        self._userProfile = normProfile
        let parentDir = (normProfile as NSString).deletingLastPathComponent
        self._usersRoot = (try? PathUtil.normalize(parentDir)) ?? normProfile
        self.downloadsDir = config.downloadsDir.flatMap { Self.tryNormalize($0) }
    }

    private static func tryNormalize(_ p: String) -> String? {
        try? PathUtil.normalize(p)
    }

    /// Why this path must never be deleted, or nil if it is allowed.
    public func getLockReason(_ path: String) -> String? {
        let p: String
        do {
            p = try PathUtil.normalize(path)
        } catch {
            return "Unsupported or unsafe path"
        }

        if p == "/" || p == "/Volumes" {
            return "Drive root"
        }
        // Reject /Volumes/<MountRoot>
        if p.hasPrefix("/Volumes/") {
            let rest = p.dropFirst("/Volumes/".count)
            if !rest.contains("/") {
                return "Drive root"
            }
        }

        // Approved disposable folders win over the protected folders that contain them (e.g. /Library/Logs/DiagnosticReports or ~/Library/Caches/...).
        if _known.contains(where: { PathUtil.isUnder(p, $0.path) }) {
            return nil
        }

        let name = (p as NSString).lastPathComponent.lowercased()
        if Self.protectedFileNames.contains(name)
            || name.hasPrefix("swapfile")
            || name.hasPrefix("ntuser.")
            || name.hasPrefix("usrclass.dat")
        {
            return "macOS system file"
        }

        for root in _protectedRoots {
            if PathUtil.isSameOrUnder(p, root) {
                return "Protected macOS or application folder"
            }
            if PathUtil.isUnder(root, p) {
                return "Contains protected system folders"
            }
        }

        if PathUtil.isUnder(p, _usersRoot)
            && !PathUtil.isSameOrUnder(p, _userProfile)
            && !PathUtil.isUnder(_userProfile, p)
        {
            return "Belongs to another user profile"
        }

        if PathUtil.isUnder(_userProfile, p) || p.caseInsensitiveCompare(_userProfile) == .orderedSame {
            return "Contains your user profile"
        }

        return nil
    }

    /// Why a whole file or folder may not be deleted: everything in `getLockReason`, plus the approved
    /// cache folders themselves (only their contents may be cleaned). Nil means it may be deleted.
    public func getDeleteBlockReason(_ path: String) -> String? {
        if let reason = getLockReason(path) {
            return reason
        }
        guard let norm = try? PathUtil.normalize(path) else {
            return "Unsupported or unsafe path"
        }
        if isKnownLocationRoot(norm) {
            return "Cache folder: only its contents can be cleaned"
        }
        return nil
    }

    /// True if the (normalized) path is exactly one of the approved cache/disposable folders.
    public func isKnownLocationRoot(_ normalizedPath: String) -> Bool {
        _known.contains { $0.path.caseInsensitiveCompare(normalizedPath) == .orderedSame }
    }

    public func isInDownloads(_ normalizedPath: String) -> Bool {
        guard let dl = downloadsDir else { return false }
        return PathUtil.isUnder(normalizedPath, dl)
    }

    // ---------------------------------------------------------------------------------------------

    public static func createDefault() -> Rules {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let library = PathUtil.combine(home, "Library")
        let caches = PathUtil.combine(library, "Caches")
        let appSupport = PathUtil.combine(library, "Application Support")
        let downloads = PathUtil.combine(home, "Downloads")

        var prot: [String] = [
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/Library",
            "/Applications",
            "/cores",
            "/dev",
            "/opt",
            "/private/etc",
            "/private/var/db",
            "/private/var/vm",
            "/private/var/root",
            "/.Spotlight-V100",
            "/.fseventsd",
            "/.DocumentRevisions-V100",
            "/.TemporaryItems",
            "/.Trashes",
            "/.vol",
            // Protect crucial user credential & application data stores inside ~/Library
            PathUtil.combine(library, "Keychains"),
            PathUtil.combine(library, "Preferences"),
            PathUtil.combine(library, "Mail"),
            PathUtil.combine(library, "Messages"),
            PathUtil.combine(library, "Safari"),
            PathUtil.combine(library, "Calendars"),
            PathUtil.combine(library, "Contacts"),
            PathUtil.combine(library, "Photos"),
            PathUtil.combine(library, "Cookies"),
            PathUtil.combine(library, "Accounts")
        ]

        for vol in MacOSIntegration.listVolumes() where vol.root != "/" {
            for sysDir in [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", ".Trashes"] {
                prot.append(PathUtil.combine(vol.root, sysDir))
            }
        }

        var known: [KnownLocation] = []
        func add(_ path: String, _ cat: Category, _ label: String, perChild: Bool, minAge: TimeInterval? = nil, admin: Bool = false) {
            known.append(KnownLocation(path: path, category: cat, label: label, perChild: perChild, minAge: minAge, needsAdmin: admin))
        }

        // 1. Temporary files (per-child, 24h min age)
        add(NSTemporaryDirectory(), .temp, "User temp file", perChild: true, minAge: tempMinAge)
        add("/private/tmp", .temp, "System temp file", perChild: true, minAge: tempMinAge)

        // 2. Crash reports & diagnostic data
        add(PathUtil.combine(library, "Logs/DiagnosticReports"), .crashData, "App crash report", perChild: true)
        add("/Library/Logs/DiagnosticReports", .crashData, "System crash report", perChild: true, admin: true)

        // 3. macOS & Xcode Updates / DeviceSupport
        add(PathUtil.combine(library, "Updates"), .systemUpdates, "macOS update download", perChild: true)
        add("/Library/Updates", .systemUpdates, "System update download", perChild: true, admin: true)
        add(PathUtil.combine(library, "Developer/Xcode/iOS DeviceSupport"), .systemUpdates, "Xcode iOS device symbols", perChild: true, minAge: logMinAge)
        add(PathUtil.combine(library, "Developer/Xcode/watchOS DeviceSupport"), .systemUpdates, "Xcode watchOS device symbols", perChild: true, minAge: logMinAge)

        // 4. App & developer caches (whole-folder contents-only)
        add(PathUtil.combine(library, "Developer/Xcode/DerivedData"), .appCache, "Xcode DerivedData build cache", perChild: false)
        add(PathUtil.combine(caches, "com.apple.dt.Xcode"), .appCache, "Xcode cache", perChild: false)
        add(PathUtil.combine(caches, "Homebrew"), .appCache, "Homebrew download cache", perChild: false)
        add(PathUtil.combine(caches, "pip"), .appCache, "pip cache", perChild: false)
        add(PathUtil.combine(caches, "Yarn"), .appCache, "Yarn cache", perChild: false)
        add(PathUtil.combine(caches, "pnpm"), .appCache, "pnpm cache", perChild: false)
        add(PathUtil.combine(caches, "CocoaPods"), .appCache, "CocoaPods cache", perChild: false)
        add(PathUtil.combine(caches, "org.swift.swiftpm"), .appCache, "Swift Package Manager cache", perChild: false)
        add(PathUtil.combine(caches, "com.apple.helpd"), .appCache, "macOS Help cache", perChild: false)
        add(PathUtil.combine(home, ".npm/_cacache"), .appCache, "npm cache", perChild: false)
        add(PathUtil.combine(home, ".local/share/NuGet/v3-cache"), .appCache, "NuGet HTTP cache", perChild: false)

        // 5. Browser caches only: never profiles, cookies, history, or passwords.
        add(PathUtil.combine(caches, "com.apple.Safari"), .browserCache, "Safari cache", perChild: false)
        add(PathUtil.combine(caches, "company.thebrowser.Browser"), .browserCache, "Arc browser cache", perChild: false)

        let chromiumCaches: [(name: String, cacheRoot: String, appSupportRoot: String)] = [
            ("Chrome", PathUtil.combine(caches, "Google/Chrome"), PathUtil.combine(appSupport, "Google/Chrome")),
            ("Brave", PathUtil.combine(caches, "BraveSoftware/Brave-Browser"), PathUtil.combine(appSupport, "BraveSoftware/Brave-Browser")),
            ("Edge", PathUtil.combine(caches, "Microsoft Edge"), PathUtil.combine(appSupport, "Microsoft Edge"))
        ]
        for (name, cacheRoot, supportRoot) in chromiumCaches {
            for prof in safeDirs(cacheRoot) {
                let pn = (prof as NSString).lastPathComponent
                if pn != "Default" && !pn.hasPrefix("Profile ") { continue }
                for sub in ["Cache", "Code Cache", "GPUCache"] {
                    add(PathUtil.combine(prof, sub), .browserCache, "\(name) \(sub.lowercased()) (\(pn))", perChild: false)
                }
            }
            for prof in safeDirs(supportRoot) {
                let pn = (prof as NSString).lastPathComponent
                if pn != "Default" && !pn.hasPrefix("Profile ") { continue }
                for sub in ["Cache", "Code Cache", "GPUCache", "ShaderCache"] {
                    add(PathUtil.combine(prof, sub), .browserCache, "\(name) \(sub.lowercased()) (\(pn))", perChild: false)
                }
            }
        }

        let ffProfiles = PathUtil.combine(caches, "Firefox/Profiles")
        for prof in safeDirs(ffProfiles) {
            add(PathUtil.combine(prof, "cache2"), .browserCache, "Firefox cache", perChild: false)
        }

        return Rules(
            RulesConfig(
                protectedRoots: prot,
                knownLocations: known,
                userProfile: home,
                downloadsDir: downloads
            )
        )
    }

    private static func safeDirs(_ dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return names.map { PathUtil.combine(dir, $0) }
    }
}
