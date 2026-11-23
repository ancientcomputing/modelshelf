import Darwin
import Foundation

/// App Sandbox support. Inside the sandbox Model Shelf can only touch folders the user picked;
/// it keeps that access across launches with security-scoped bookmarks.
public enum Sandbox {
    public static var isActive: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// The user's real home folder. `NSHomeDirectory()` is the app's container when sandboxed.
    public static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }
}

public enum HubFolder {
    /// The user may pick the hub folder itself (`…/hub`, full of `models--…` folders) or its parent
    /// (`~/.cache/huggingface`, `/Volumes/Work/models`). Use `hub/` inside the pick when the pick
    /// isn't a hub but has one.
    public static func hub(forPicked url: URL) -> URL {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        if names.contains(where: RepoName.isRepoDir) { return url }
        var isDir: ObjCBool = false
        let child = url.appendingPathComponent("hub")
        if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue { return child }
        return url
    }
}

/// One user-granted folder, remembered as a security-scoped bookmark.
public final class GrantedFolder: @unchecked Sendable {
    /// What the user picked (the bookmark's target).
    public private(set) var url: URL?
    /// Bookmark data to persist; refreshed when macOS reports it stale.
    public private(set) var bookmark: Data?
    private var accessing = false

    public init(bookmark: Data?) {
        self.bookmark = bookmark
        _ = resolve()
    }

    public var isGranted: Bool { bookmark != nil }
    public var isAccessible: Bool { url != nil }

    /// Grants access to `url`, which the user just picked in an open panel.
    public func grant(_ picked: URL) throws {
        stop()
        bookmark = try picked.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        _ = resolve()
    }

    public func revoke() {
        stop()
        bookmark = nil
        url = nil
    }

    /// Resolves the bookmark and starts access. Fails (returns false) while the folder's volume
    /// isn't mounted; call again after a mount. Returns true when the bookmark data changed.
    @discardableResult
    public func resolve() -> Bool {
        guard let data = bookmark, url == nil else { return false }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: resolved.path) else { return false }
        accessing = resolved.startAccessingSecurityScopedResource()
        url = resolved
        if stale, let fresh = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmark = fresh
            return true
        }
        return false
    }

    /// Forgets the resolved URL (e.g. the drive was ejected) so the next `resolve()` tries again.
    public func invalidateIfMissing() {
        guard let u = url, !FileManager.default.fileExists(atPath: u.path) else { return }
        stop()
        url = nil
    }

    private func stop() {
        if accessing, let u = url { u.stopAccessingSecurityScopedResource() }
        accessing = false
    }

    deinit { stop() }
}
