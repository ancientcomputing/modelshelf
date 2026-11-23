import Foundation

/// One line of the activity log: something that changed (or was attempted) in the cache or library.
public struct ActivityEntry: Codable, Sendable, Identifiable, Hashable {
    public enum Outcome: String, Codable, Sendable { case succeeded, failed, cancelled }

    public var id = UUID()
    public var date: Date
    /// e.g. "Moved to library", "Repaired library copy", "Downloaded".
    public var action: String
    public var repoID: String
    public var outcome: Outcome
    /// The commit the model is at (for a download: the commit that was fetched).
    public var revision: String?
    /// Where `revision` came from for a download, e.g. "library copy", "LocalLM Lab pin", "latest (main)".
    public var revisionSource: String?
    /// Bytes copied, downloaded or freed, depending on the action.
    public var bytes: Int64?
    public var duration: TimeInterval?
    public var detail: String?

    public init(date: Date = Date(), action: String, repoID: String, outcome: Outcome,
                revision: String? = nil, revisionSource: String? = nil, bytes: Int64? = nil,
                duration: TimeInterval? = nil, detail: String? = nil) {
        self.date = date
        self.action = action
        self.repoID = repoID
        self.outcome = outcome
        self.revision = revision
        self.revisionSource = revisionSource
        self.bytes = bytes
        self.duration = duration
        self.detail = detail
    }
}

/// Append-only JSON Lines file, one `ActivityEntry` per line. Survives app restarts; readable with
/// `jq` or any text editor.
public final class ActivityLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("ModelShelf/activity.jsonl")
    }

    public init(url: URL = ActivityLog.defaultURL) { self.url = url }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func append(_ entry: ActivityEntry) throws {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// All entries, oldest first. Lines that don't parse are skipped.
    public func load() -> [ActivityEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(ActivityEntry.self, from: Data($0)) }
    }
}
