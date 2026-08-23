import Foundation

/// Turning an absolute file URL back into the path a vault knows it by.
public enum VaultPath {

    /// `url` expressed relative to `root`, extension included.
    ///
    /// Falls back to the file's own name rather than to the absolute path: this
    /// feeds things a person copies and pastes, and a "relative path" that
    /// silently turns out to be `/Users/…` is worse than a bare filename,
    /// because it looks right.
    ///
    /// The symlink step is not defensive padding. A vault under `/var/…` is
    /// handed back by the file system as `/private/var/…`, so comparing the two
    /// forms directly fails on exactly the vaults that live in a temporary or
    /// linked directory — the same trap `SyncEngine.localFiles` has a comment
    /// about, arrived at there by watching a whole tree flatten onto its root.
    /// The raw comparison is tried first, so the ordinary case costs nothing.
    public static func relative(of url: URL, in root: URL) -> String {
        let path = url.path(percentEncoded: false)
        let rootPath = root.path(percentEncoded: false)

        if let trimmed = strip(prefix: rootPath, from: path) { return trimmed }

        let canonicalRoot = (rootPath as NSString).resolvingSymlinksInPath
        let canonical = (path as NSString).resolvingSymlinksInPath
        if let trimmed = strip(prefix: canonicalRoot, from: canonical) { return trimmed }

        return url.lastPathComponent
    }

    /// `nil` when `path` is not inside `prefix`. A trailing slash is added to the
    /// prefix before comparing so that `/vault-backup/Note.md` is not read as
    /// being inside `/vault`.
    private static func strip(prefix: String, from path: String) -> String? {
        let base = prefix.hasSuffix("/") ? prefix : prefix + "/"
        guard path.hasPrefix(base) else { return nil }
        let relative = String(path.dropFirst(base.count))
        return relative.isEmpty ? nil : relative
    }
}
