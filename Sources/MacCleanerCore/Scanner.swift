import Foundation

/// Read-only. Walks the chosen locations and reports what could be cleaned; deletes nothing.
public final class Scanner: Sendable {
    private let _rules: Rules

    public init(_ rules: Rules) {
        self._rules = rules
    }

    public func scanAsync(
        _ options: ScanOptions,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> ScanResult {
        let run = ScanRun(rules: _rules, options: options)
        if Task.isCancelled {
            run.cancel()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            run.execute()
        }

        while !run.isFinished {
            if Task.isCancelled {
                run.cancel()
                break
            }
            progress?(run.snapshot())
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if Task.isCancelled {
            run.cancel()
        }
        while !run.isFinished {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let snap = run.snapshot()
        progress?(snap)
        return run.toResult()
    }
}

private final class ScanRun: @unchecked Sendable {
    private static let skipDirNames: Set<String> = [
        ".trash",
        ".trashes",
        ".spotlight-v100",
        ".fseventsd",
        ".documentrevisions-v100",
        ".temporaryitems",
        "$recycle.bin",
        "system volume information"
    ]

    private static let installerExts: Set<String> = [
        ".dmg", ".pkg", ".mpkg", ".zip", ".7z", ".rar", ".tar", ".gz", ".tgz", ".tbz2", ".xz", ".iso", ".img", ".exe", ".msi", ".msix", ".cab"
    ]

    private static let crashExts: Set<String> = [
        ".crash", ".ips", ".dmp", ".mdmp", ".spin", ".hang"
    ]

    private static let logExts: Set<String> = [
        ".log", ".asl", ".etl"
    ]

    private let _rules: Rules
    private let _options: ScanOptions
    private let _lock = NSLock()
    private let _startTime = Date()

    private var _findings: [Finding] = []
    private var _claimed: Set<String> = []
    private var _files: Int64 = 0
    private var _bytes: Int64 = 0
    private var _foundBytes: Int64 = 0
    private var _denied: Int = 0
    private var _count: Int = 0
    private var _current: String = ""
    private var _cancelled: Bool = false
    private var _finished: Bool = false

    init(rules: Rules, options: ScanOptions) {
        self._rules = rules
        self._options = options
    }

    func cancel() {
        _lock.lock()
        _cancelled = true
        _lock.unlock()
    }

    var isCancelled: Bool {
        _lock.lock()
        defer { _lock.unlock() }
        return _cancelled
    }

    var isFinished: Bool {
        _lock.lock()
        defer { _lock.unlock() }
        return _finished
    }

    private func markFinished() {
        _lock.lock()
        _finished = true
        _lock.unlock()
    }

    func snapshot() -> ScanProgress {
        _lock.lock()
        defer { _lock.unlock() }
        return ScanProgress(
            filesScanned: _files,
            bytesScanned: _bytes,
            foundBytes: _foundBytes,
            findingCount: _count,
            deniedFolders: _denied,
            currentFolder: _current
        )
    }

    func toResult() -> ScanResult {
        _lock.lock()
        defer { _lock.unlock() }
        let sorted = _findings.sorted { $0.size > $1.size }
        return ScanResult(
            findings: sorted,
            deniedFolders: _denied,
            filesScanned: _files,
            bytesScanned: _bytes,
            elapsed: Date().timeIntervalSince(_startTime),
            cancelled: _cancelled
        )
    }

    private func add(_ f: Finding) {
        _lock.lock()
        _findings.append(f)
        if f.tier != .locked {
            _foundBytes += f.size
        }
        _count += 1
        _lock.unlock()
    }

    private func recordDirectoryProgress(dir: String, files: Int64, bytes: Int64) {
        _lock.lock()
        _current = dir
        _files += files
        _bytes += bytes
        _lock.unlock()
    }

    private func addStats(files: Int64, bytes: Int64) {
        _lock.lock()
        _files += files
        _bytes += bytes
        _lock.unlock()
    }

    private func onDenied() {
        _lock.lock()
        _denied += 1
        _lock.unlock()
    }

    private func setCurrent(_ dir: String) {
        _lock.lock()
        _current = dir
        _lock.unlock()
    }

    private func claim(_ path: String) {
        _lock.lock()
        _claimed.insert(path.lowercased())
        _lock.unlock()
    }

    private func isClaimed(_ path: String) -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        return _claimed.contains(path.lowercased())
    }

    func execute() {
        defer { markFinished() }
        if isCancelled { return }
        let roots = Self.normalizeRoots(_options.roots)
        if _options.includeKnownLocations {
            for k in _rules.knownLocations {
                if isCancelled { return }
                if roots.contains(where: { PathUtil.isSameOrUnder(k.path, $0) }) {
                    scanKnownLocation(k)
                }
            }
            addTrash(roots: roots)
        }
        if isCancelled { return }
        walk(roots: roots)
    }

    private static func normalizeRoots(_ input: [String]) -> [String] {
        var all: [String] = []
        for r in input {
            guard let n = try? PathUtil.normalize(r) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: n, isDirectory: &isDir), isDir.boolValue {
                if !all.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) {
                    all.append(n)
                }
            }
        }
        // Drop roots nested inside another root so nothing is scanned twice.
        return all.filter { a in
            !all.contains { b in PathUtil.isUnder(a, b) }
        }
    }

    // ---- Known disposable locations ----------------------------------------------------------------

    private func scanKnownLocation(_ k: KnownLocation) {
        if isCancelled { return }
        var st = stat()
        guard lstat(k.path, &st) == 0 else { return }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK || mode != S_IFDIR { return }

        // Skip if any part of the path is a link: we could end up cleaning somewhere else.
        guard let finalPath = PathUtil.resolveFinal(k.path),
              finalPath.caseInsensitiveCompare(k.path) == .orderedSame,
              !PathUtil.hasSymlinkComponent(k.path) else {
            return
        }

        claim(k.path)
        setCurrent(k.path)
        let suffix = k.needsAdmin ? " (needs administrator)" : ""
        let dirModUtc = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0)

        if !k.perChild {
            let m = FsUtil.measure(
                k.path,
                isCancelled: { [weak self] in self?.isCancelled ?? true },
                onDenied: { [weak self] in self?.onDenied() },
                onDirectory: { [weak self] dir, files, bytes in
                    self?.recordDirectoryProgress(dir: dir, files: files, bytes: bytes)
                }
            )
            if m.bytes <= 0 { return }
            let newest = m.newestUtc == .distantPast ? dirModUtc : m.newestUtc
            add(
                Finding(
                    path: k.path,
                    isDirectory: true,
                    size: m.bytes,
                    modifiedUtc: newest,
                    stampUtc: dirModUtc,
                    category: k.category,
                    tier: .safe,
                    reason: "Rebuilt automatically when needed" + suffix,
                    contentsOnly: true,
                    label: k.label,
                    needsAdmin: k.needsAdmin
                )
            )
            return
        }

        let children: [FsEntry]
        do {
            children = try FsUtil.enumerate(k.path)
        } catch FsError.accessDenied {
            onDenied()
            return
        } catch {
            return
        }

        for child in children {
            if isCancelled { return }
            if child.isSymlink || child.isCloudOnly { continue }
            let path = PathUtil.combine(k.path, child.name)
            let size: Int64
            let newest: Date
            if child.isDirectory {
                let m = FsUtil.measure(
                    path,
                    isCancelled: { [weak self] in self?.isCancelled ?? true },
                    onDenied: { [weak self] in self?.onDenied() },
                    onDirectory: { [weak self] dir, files, bytes in
                        self?.recordDirectoryProgress(dir: dir, files: files, bytes: bytes)
                    }
                )
                size = m.bytes
                newest = m.files > 0 ? m.newestUtc : child.lastWriteUtc
            } else {
                if child.isSystemImmutable { continue }
                size = child.length
                newest = child.lastWriteUtc
                addStats(files: 1, bytes: size)
            }
            if size <= 0 { continue }
            let age = Date().timeIntervalSince(newest)
            if let minAge = k.minAge, age < minAge { continue }

            let ageNote = k.minAge == nil ? "" : ", unused for \(Format.age(age))"
            let reason = k.label + ageNote + suffix
            add(
                Finding(
                    path: path,
                    isDirectory: child.isDirectory,
                    size: size,
                    modifiedUtc: newest,
                    stampUtc: child.lastWriteUtc,
                    category: k.category,
                    tier: .safe,
                    reason: reason,
                    needsAdmin: k.needsAdmin
                )
            )
        }
    }

    private func addTrash(roots: [String]) {
        // Include Trash when scanning the boot drive `/` or the user's home directory
        let trashPath = MacOSIntegration.userTrashPath
        guard roots.contains(where: { $0 == "/" || PathUtil.isSameOrUnder(trashPath, $0) }) else {
            return
        }
        claim(trashPath)
        guard let info = MacOSIntegration.queryTrash(isCancelled: { [weak self] in self?.isCancelled ?? true }),
              info.size > 0 else {
            return
        }
        let now = Date()
        add(
            Finding(
                path: trashPath,
                isDirectory: true,
                size: info.size,
                modifiedUtc: now,
                stampUtc: now,
                category: .trash,
                tier: .safe,
                reason: "\(info.items) deleted item(s) waiting in the Trash. Emptying it is permanent.",
                contentsOnly: true,
                label: "Trash"
            )
        )
    }

    // ---- Whole-disk walk ---------------------------------------------------------------------------

    private func walk(roots: [String]) {
        if roots.isEmpty { return }

        let queueLock = NSCondition()
        var queue: [String] = roots
        var pending = roots.count
        let workerCount = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount * 2))

        func enqueue(_ dir: String) {
            queueLock.lock()
            pending += 1
            queue.append(dir)
            queueLock.signal()
            queueLock.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while true {
                queueLock.lock()
                while queue.isEmpty && pending > 0 && !isCancelled {
                    queueLock.wait()
                }
                if isCancelled || (queue.isEmpty && pending == 0) {
                    queueLock.unlock()
                    break
                }
                let dir = queue.removeFirst()
                queueLock.unlock()

                processDir(dir, enqueue: enqueue)

                queueLock.lock()
                pending -= 1
                if pending == 0 || isCancelled {
                    queueLock.broadcast()
                }
                queueLock.unlock()
            }
        }
    }

    private func processDir(_ dir: String, enqueue: (String) -> Void) {
        if isCancelled { return }
        setCurrent(dir)

        let entries: [FsEntry]
        do {
            entries = try FsUtil.enumerate(dir)
        } catch FsError.accessDenied {
            onDenied()
            return
        } catch {
            return
        }

        var localFiles: Int64 = 0
        var localBytes: Int64 = 0

        for e in entries {
            if isCancelled { break }
            if e.isSymlink && e.isDirectory { continue } // never follow symlinks
            if e.isCloudOnly { continue }
            let full = PathUtil.combine(dir, e.name)

            if e.isDirectory {
                let lowerName = e.name.lowercased()
                if Self.skipDirNames.contains(lowerName) || isClaimed(full) {
                    continue
                }
                // Avoid crossing into virtual/mounted filesystems or APFS Data firmlink mirror when walking `/`
                if dir == "/" && (lowerName == "dev" || lowerName == "volumes" || lowerName == "net" || lowerName == "home") {
                    continue
                }
                if full.caseInsensitiveCompare("/System/Volumes") == .orderedSame {
                    continue
                }
                if lowerName == "node_modules" {
                    evaluateNodeModules(full: full, parent: dir, entry: e)
                    continue
                }
                enqueue(full)
                continue
            }

            if e.isSymlink { continue }
            localFiles += 1
            localBytes += e.length
            evaluateFile(full: full, entry: e)
        }

        addStats(files: localFiles, bytes: localBytes)
    }

    private func evaluateFile(full: String, entry e: FsEntry) {
        let size = e.length
        let age = Date().timeIntervalSince(e.lastWriteUtc)
        let ext = "." + ((e.name as NSString).pathExtension.lowercased())
        let isLarge = size >= _options.largeFileThreshold

        let cat: Category
        let reason: String

        if size >= Rules.minRuleFileSize && Self.crashExts.contains(ext) {
            cat = .crashData
            reason = "Crash dump file"
        } else if size >= Rules.minRuleFileSize && age >= Rules.logMinAge && Self.logExts.contains(ext) {
            cat = .oldLogs
            reason = "Log file, not modified for \(Format.age(age))"
        } else if age >= Rules.downloadMinAge && Self.installerExts.contains(ext) && _rules.isInDownloads(full) {
            cat = .oldDownloads
            reason = "Installer or archive in Downloads, untouched for \(Format.age(age))"
        } else if isLarge {
            cat = .largeFile
            reason = "Large file, last changed \(Format.age(age)) ago"
        } else {
            return
        }

        let lockReason = _rules.getLockReason(full) ?? (e.isSystemImmutable ? "macOS system file" : nil)
        if let lockReason {
            // Locked items are only listed so you can see what uses space; skip the small ones.
            if isLarge {
                add(
                    Finding(
                        path: full,
                        isDirectory: false,
                        size: size,
                        modifiedUtc: e.lastWriteUtc,
                        stampUtc: e.lastWriteUtc,
                        category: .largeFile,
                        tier: .locked,
                        reason: lockReason
                    )
                )
            }
            return
        }

        add(
            Finding(
                path: full,
                isDirectory: false,
                size: size,
                modifiedUtc: e.lastWriteUtc,
                stampUtc: e.lastWriteUtc,
                category: cat,
                tier: .review,
                reason: reason
            )
        )
    }

    private func evaluateNodeModules(full: String, parent: String, entry e: FsEntry) {
        let m = FsUtil.measure(
            full,
            isCancelled: { [weak self] in self?.isCancelled ?? true },
            onDenied: { [weak self] in self?.onDenied() },
            onDirectory: { [weak self] dir, files, bytes in
                self?.recordDirectoryProgress(dir: dir, files: files, bytes: bytes)
            }
        )
        if m.bytes <= 0 || _rules.getLockReason(full) != nil { return }

        var lastActive = m.newestUtc == .distantPast ? e.lastWriteUtc : m.newestUtc
        let pkgPath = PathUtil.combine(parent, "package.json")
        var st = stat()
        if lstat(pkgPath, &st) == 0 {
            let pkgDate = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0)
            if pkgDate > lastActive {
                lastActive = pkgDate
            }
        }

        let age = Date().timeIntervalSince(lastActive)
        if age < Rules.nodeModulesMinAge { return }

        add(
            Finding(
                path: full,
                isDirectory: true,
                size: m.bytes,
                modifiedUtc: lastActive,
                stampUtc: e.lastWriteUtc,
                category: .nodeModules,
                tier: .review,
                reason: "Project dependencies, no changes for \(Format.age(age)). Restore with npm install."
            )
        )
    }
}
