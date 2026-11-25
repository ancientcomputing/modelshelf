import Foundation

/// Health of one repo folder (`models--org--name`) in a Hugging Face hub cache.
public enum RepoHealth: Sendable, Hashable {
    case ok
    case downloading
    case broken(String)

    public var isOK: Bool { if case .ok = self { return true } else { return false } }
}

/// A scanned repo folder. The folder is self-contained: `blobs/` holds the data,
/// `snapshots/<rev>/` holds relative symlinks into `../../blobs`, `refs/` maps branches to revs.
public struct RepoInfo: Sendable, Hashable {
    public let dirName: String
    public let url: URL
    /// Blob file name -> size in bytes.
    public let blobs: [String: Int64]
    public let snapshots: Set<String>
    /// Every file path under `snapshots/` (e.g. `abc123/config.json`), links and regular files.
    public let snapshotFiles: Set<String>
    /// `refs/<name>` -> commit, e.g. `["main": "abc123..."]`.
    public let refs: [String: String]
    public let sizeBytes: Int64
    public let modified: Date
    public let health: RepoHealth

    public var repoID: String { RepoName.repoID(dirName) }

    /// The single commit this copy is at: the one `refs/main` points to, or the only snapshot.
    /// Nil when there are several snapshots and no ref says which one is current.
    public var currentRevision: String? {
        if let main = refs["main"], snapshots.contains(main) { return main }
        return snapshots.count == 1 ? snapshots.first : nil
    }

    /// True when this copy holds every blob (same size), every snapshot revision and every
    /// snapshot file of `other` — i.e. deleting `other` loses nothing.
    public func covers(_ other: RepoInfo) -> Bool {
        other.blobs.allSatisfy { blobs[$0.key] == $0.value }
            && other.snapshots.isSubset(of: snapshots)
            && other.snapshotFiles.isSubset(of: snapshotFiles)
    }
}

public enum RepoName {
    static let prefixes = ["models--", "datasets--", "spaces--"]

    public static func isRepoDir(_ name: String) -> Bool {
        prefixes.contains { name.hasPrefix($0) }
    }

    /// `models--mlx-community--Qwen3-4B-4bit` -> `mlx-community/Qwen3-4B-4bit`
    /// `mlx-community/Qwen3-4B-4bit` -> `models--mlx-community--Qwen3-4B-4bit`
    public static func dirName(forModel repoID: String) -> String {
        "models--" + repoID.replacingOccurrences(of: "/", with: "--")
    }

    public static func repoID(_ dirName: String) -> String {
        guard let p = prefixes.first(where: { dirName.hasPrefix($0) }) else { return dirName }
        return String(dirName.dropFirst(p.count)).replacingOccurrences(of: "--", with: "/")
    }
}

public enum ShelfError: LocalizedError, Equatable {
    case notFound(String)
    case sourceNotReady(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case verifyFailed(String)
    case libraryDoesNotCover(String)
    case destinationBusy(String)
    case sourceDamaged(String)
    case io(String)
    case hub(String)
    case cancelled

    public var errorDescription: String? {
        let f = ByteCountFormatter()
        switch self {
        case .notFound(let p): return "Couldn't find \(p)."
        case .sourceNotReady(let r): return "The source copy isn't ready: \(r)."
        case .notEnoughSpace(let n, let a):
            return "Not enough space. It needs \(f.string(fromByteCount: n)) and only \(f.string(fromByteCount: a)) is free."
        case .verifyFailed(let r): return "Verification failed: \(r). Nothing was deleted."
        case .libraryDoesNotCover(let r): return "The library copy isn't complete (\(r)), so the Mac copy was kept."
        case .destinationBusy(let r): return "Nothing was changed: \(r). Try again when it's finished."
        case .sourceDamaged(let b): return "A file in the copy being copied from is damaged (\(b)…), so it wasn't copied over the other copy. Repair or redownload that copy first."
        case .io(let r): return r
        case .hub(let r): return r
        case .cancelled: return "Cancelled."
        }
    }
}

public enum Scanner {
    /// Scans a hub folder (e.g. `~/.cache/huggingface/hub`). Returns [] if it doesn't exist.
    public static func scan(hub: URL) -> [RepoInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: hub.path)) ?? []
        return names.filter(RepoName.isRepoDir).compactMap { try? inspect(repo: hub.appendingPathComponent($0)) }
    }

    /// True when `snapshots/<revision>` has content and every link in it resolves.
    public static func revisionIsComplete(repo: URL, revision: String) -> Bool {
        let fm = FileManager.default
        let dir = repo.appendingPathComponent("snapshots/\(revision)")
        guard let en = fm.enumerator(atPath: dir.path) else { return false }
        var content = 0
        while let rel = en.nextObject() as? String {
            let path = dir.appendingPathComponent(rel).path
            guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { continue }
            if type == .typeSymbolicLink {
                guard fm.fileExists(atPath: path) else { return false }
                content += 1
            } else if type == .typeRegular, !(rel as NSString).lastPathComponent.hasPrefix(".") {
                content += 1
            }
        }
        return content > 0
    }

    public static func inspect(repo: URL) throws -> RepoInfo {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: repo.path, isDirectory: &isDir), isDir.boolValue else {
            throw ShelfError.notFound(repo.path)
        }

        var blobs: [String: Int64] = [:]
        var downloading = false
        let blobsDir = repo.appendingPathComponent("blobs")
        for name in (try? fm.contentsOfDirectory(atPath: blobsDir.path)) ?? [] {
            if name.hasSuffix(".incomplete") { downloading = true; continue }
            let attrs = try fm.attributesOfItem(atPath: blobsDir.appendingPathComponent(name).path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            blobs[name] = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }

        // `content` ignores hidden regular files such as `.locallm-download-complete` markers:
        // a snapshot holding only a marker has no usable model files.
        var content = 0, dangling = 0
        var snapshotFiles = Set<String>()
        var looseBytes: Int64 = 0
        let snapsDir = repo.appendingPathComponent("snapshots")
        let snapshots = Set((try? fm.contentsOfDirectory(atPath: snapsDir.path))?.filter { !$0.hasPrefix(".") } ?? [])
        if let en = fm.enumerator(atPath: snapsDir.path) {
            while let rel = en.nextObject() as? String {
                let path = snapsDir.appendingPathComponent(rel).path
                // attributesOfItem does not follow symlinks.
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let type = attrs[.type] as? FileAttributeType else { continue }
                if type == .typeSymbolicLink {
                    content += 1
                    snapshotFiles.insert(rel)
                    if !fm.fileExists(atPath: path) { dangling += 1 } // fileExists follows the link
                } else if type == .typeRegular {
                    snapshotFiles.insert(rel)
                    if !(rel as NSString).lastPathComponent.hasPrefix(".") { content += 1 }
                    looseBytes += (attrs[.size] as? NSNumber)?.int64Value ?? 0
                }
            }
        }

        let health: RepoHealth
        if downloading {
            health = .downloading
        } else if content == 0 {
            health = .broken(blobs.isEmpty ? "the folder is empty" : "the snapshot links are missing")
        } else if dangling > 0 {
            health = .broken("\(dangling) snapshot file\(dangling == 1 ? "" : "s") point to missing data")
        } else {
            health = .ok
        }

        var refs: [String: String] = [:]
        let refsDir = repo.appendingPathComponent("refs")
        for name in (try? fm.contentsOfDirectory(atPath: refsDir.path)) ?? [] {
            if let v = try? String(contentsOf: refsDir.appendingPathComponent(name), encoding: .utf8) {
                refs[name] = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let modified = (try? fm.attributesOfItem(atPath: repo.path)[.modificationDate] as? Date) ?? .distantPast
        return RepoInfo(
            dirName: repo.lastPathComponent,
            url: repo,
            blobs: blobs,
            snapshots: snapshots,
            snapshotFiles: snapshotFiles,
            refs: refs,
            sizeBytes: blobs.values.reduce(0, +) + looseBytes,
            modified: modified,
            health: health
        )
    }
}
