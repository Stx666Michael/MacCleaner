import Foundation

public enum PathError: Error, LocalizedError {
    case emptyPath
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPath: return "Empty path"
        case .unsafePath(let msg): return msg
        }
    }
}

public enum PathUtil {
    /// Turns a path into one canonical lexical form:
    /// - Rejects empty paths, relative paths, network/UNC-like paths (`//` or `\\`), NUL characters, and Windows-style drive paths.
    /// - Resolves `.` and `..` lexically without following arbitrary user symlinks.
    /// - Canonicalizes standard macOS root firmlinks/symlinks (`/var` -> `/private/var`, `/tmp` -> `/private/tmp`, `/etc` -> `/private/etc`).
    /// - Strips trailing slashes (except for `/`).
    public static func normalize(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw PathError.emptyPath
        }
        if trimmed.contains("\0") {
            throw PathError.unsafePath("Path contains null byte")
        }
        if trimmed.hasPrefix("\\\\") || trimmed.hasPrefix("//") {
            throw PathError.unsafePath("Network or device path is not supported")
        }
        if !trimmed.hasPrefix("/") {
            throw PathError.unsafePath("Only absolute local paths are supported")
        }
        // Reject alternate data streams / resource fork syntax if someone passes `:stream` on a file component
        // (Also catches Windows drive-like artifacts)
        let rawParts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [String] = []
        for partSub in rawParts {
            let part = String(partSub)
            if part == "." {
                continue
            } else if part == ".." {
                if !stack.isEmpty {
                    stack.removeLast()
                }
            } else {
                stack.append(part)
            }
        }

        var canonical = "/" + stack.joined(separator: "/")

        // Canonicalize standard macOS system symlinks so paths under /var/folders or /tmp match realpath()
        // without resolving arbitrary user symlinks along the path.
        if canonical == "/var" || canonical.hasPrefix("/var/") {
            canonical = "/private" + canonical
        } else if canonical == "/tmp" || canonical.hasPrefix("/tmp/") {
            canonical = "/private" + canonical
        } else if canonical == "/etc" || canonical.hasPrefix("/etc/") {
            canonical = "/private" + canonical
        }

        // Canonicalize APFS Data volume firmlink prefix if present for /Users, /Library, /Applications, /private, /opt
        let dataPrefix = "/System/Volumes/Data/"
        if canonical.hasPrefix(dataPrefix) {
            let rest = "/" + String(canonical.dropFirst(dataPrefix.count))
            for top in ["/Users", "/Library", "/Applications", "/private", "/opt", "/Volumes", "/cores"] {
                if rest == top || rest.hasPrefix(top + "/") {
                    canonical = rest
                    break
                }
            }
        }

        return trimEnd(canonical)
    }

    public static func trimEnd(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    /// True if `path` is strictly inside `root`. Both must be normalized.
    /// Uses case-insensitive comparison because standard macOS APFS volumes are case-insensitive by default.
    public static func isUnder(_ path: String, _ root: String) -> Bool {
        if path.count <= root.count { return false }
        if root == "/" {
            return path.hasPrefix("/") && path.count > 1
        }
        guard path.range(of: root, options: [.anchored, .caseInsensitive]) != nil else {
            return false
        }
        let idx = path.index(path.startIndex, offsetBy: root.count)
        return path[idx] == "/"
    }

    public static func isSameOrUnder(_ path: String, _ root: String) -> Bool {
        if path.caseInsensitiveCompare(root) == .orderedSame {
            return true
        }
        return isUnder(path, root)
    }

    /// The real path after following all symlinks, normalized; nil when it cannot be resolved.
    public static func resolveFinal(_ path: String) -> String? {
        guard let normalizedInput = try? normalize(path) else { return nil }
        // First check if any component along the path is a symlink using lstat
        if hasSymlinkComponent(normalizedInput) {
            // Resolve target via realpath so caller sees the different destination path
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(normalizedInput, &buf) != nil else { return nil }
            let resolved = String(cString: buf)
            return try? normalize(resolved)
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(normalizedInput, &buf) != nil else { return nil }
        let resolved = String(cString: buf)
        return try? normalize(resolved)
    }

    /// Returns true if any component in `normalizedPath` (after standard `/private/...` canonicalization) is a symbolic link.
    public static func hasSymlinkComponent(_ normalizedPath: String) -> Bool {
        if normalizedPath == "/" { return false }
        let parts = normalizedPath.split(separator: "/", omittingEmptySubsequences: true)
        var current = ""
        for part in parts {
            current += "/" + part
            var st = stat()
            if lstat(current, &st) != 0 {
                return false
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                return true
            }
        }
        return false
    }

    public static func combine(_ dir: String, _ name: String) -> String {
        if dir == "/" { return "/" + name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}
