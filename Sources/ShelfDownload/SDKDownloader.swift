import Darwin
import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import ShelfCore

public struct DownloadOutcome: Sendable {
    /// The commit now in the library.
    public let commit: String
    public let bytesDownloaded: Int64
    public let prelink: PrelinkResult
    /// How the download was merged into the library copy.
    public let merge: CopyReport
    public var repo: RepoInfo { merge.repo }
}

/// Re-downloads a model into the library through the LocalLM SDK, without letting anything write
/// into the library copy directly:
/// 1. resolve the requested revision to a commit (so a moving `main` can't change mid-way);
/// 2. set up a private staging copy on the same drive, seeded with clones (or hard links) of the
///    files the library copy already has, and re-link the ones whose hashes check out, so nothing is
///    fetched twice. Files that fail the check are dropped from the staging copy only;
/// 3. `MLXModelProvider(cacheDirectory: staging, pinnedRevisions: [repo: commit]).download(repo)`
///    fetches and verifies whatever is still missing;
/// 4. check the result is complete, then merge it into the library with `Transfer.backup`: it
///    only adds, keeps the library's other revisions and refs, and replaces a library file only
///    when that file fails its hash check.
public enum SDKDownloader {
    public static func download(
        repoID: String,
        choice: RevisionChoice,
        libraryHub: URL,
        cancel: CancelToken,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> DownloadOutcome {
        let fm = FileManager.default
        let dirName = RepoName.dirName(forModel: repoID)
        let libRepo = libraryHub.appendingPathComponent(dirName)
        let existing = fm.fileExists(atPath: libRepo.path) ? try Scanner.inspect(repo: libRepo) : nil
        if existing?.health == .downloading {
            throw ShelfError.destinationBusy("the library copy is still downloading")
        }

        let meta = try await Hub.fetchRevision(repoID: repoID, revision: choice.revision)
        if choice.isPinned, meta.sha != choice.revision.lowercased() {
            throw ShelfError.hub("Hugging Face resolved \(choice.revision) to a different commit (\(meta.sha)).")
        }

        try fm.createDirectory(at: libraryHub, withIntermediateDirectories: true)
        let stagingHub = Transfer.newStaging(in: libraryHub)
        try fm.createDirectory(at: stagingHub, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stagingHub) } // only the staging copy: links and our own downloads
        let repoDir = stagingHub.appendingPathComponent(dirName)
        try fm.createDirectory(at: repoDir.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        // Seed with the library's files without copying them. A clone (APFS) is a separate file
        // sharing the data, so nothing done to it reaches the library's file; elsewhere a hard
        // link at least keeps deletes and renames here from touching it.
        for name in existing?.blobs.keys.sorted() ?? [] {
            let from = libRepo.appendingPathComponent("blobs/\(name)").path
            let to = repoDir.appendingPathComponent("blobs/\(name)").path
            if Darwin.clonefile(from, to, 0) != 0 { _ = Darwin.link(from, to) }
        }
        let marker = "snapshots/\(meta.sha)/.locallm-download-complete"
        if fm.fileExists(atPath: libRepo.appendingPathComponent(marker).path) {
            try fm.createDirectory(at: repoDir.appendingPathComponent("snapshots/\(meta.sha)"), withIntermediateDirectories: true)
            try fm.copyItem(at: libRepo.appendingPathComponent(marker), to: repoDir.appendingPathComponent(marker))
        }

        let prelink = try await Task.detached(priority: .userInitiated) {
            try Prelinker.prelink(meta, repo: repoDir, cancel: cancel, progress: progress)
        }.value
        if cancel.isCancelled { throw ShelfError.cancelled }
        // A same-named blob that's present would be kept by the SDK's cache instead of the fresh
        // copy. Unlinking it here leaves the library's file as it is.
        for name in prelink.corrupt {
            try fm.removeItem(at: repoDir.appendingPathComponent("blobs/\(name)"))
        }

        // Space for whatever the SDK still has to fetch.
        var seen = Set<String>()
        let remaining = meta.siblings.filter { f in
            let link = repoDir.appendingPathComponent("snapshots/\(meta.sha)/\(f.rfilename)")
            return !fm.fileExists(atPath: link.path) && seen.insert(f.blobName).inserted
        }.reduce(Int64(0)) { $0 + $1.byteSize }
        if let free = Transfer.freeSpace(libraryHub), free < remaining + (512 << 20) {
            throw ShelfError.notEnoughSpace(needed: remaining, available: free)
        }

        var commit = meta.sha
        if remaining > 0 || !fm.fileExists(atPath: repoDir.appendingPathComponent(marker).path) {
            let provider = MLXModelProvider(
                cacheDirectory: stagingHub, pinnedRevisions: [repoID: meta.sha], promptCache: .off)
            let throttle = Throttle()
            let stream = provider.download(repoID)
            let watcher = Task.detached {
                while !Task.isCancelled {
                    if cancel.isCancelled { provider.cancelDownload(repoID); return }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            do {
                for try await event in stream {
                    switch event {
                    case .progress(let got, let total, _):
                        if throttle.ready() { progress(TransferProgress(phase: .downloading, done: got, total: max(total, got))) }
                    case .completed(let model):
                        commit = model.resolvedRevision
                    @unknown default:
                        break
                    }
                }
            } catch {
                if cancel.isCancelled || error is CancellationError { throw ShelfError.cancelled }
                throw ShelfError.hub("The LocalLM SDK download failed: \(error.localizedDescription)")
            }
        }

        // Check everything the SDK delivered (what the pre-link step didn't already verify).
        var checked = prelink.verifiedBlobs
        for f in meta.siblings where checked.insert(f.blobName).inserted {
            if cancel.isCancelled { throw ShelfError.cancelled }
            guard try Prelinker.verify(repoDir.appendingPathComponent("blobs/\(f.blobName)"), file: f, cancel: cancel, progress: progress) else {
                throw ShelfError.verifyFailed("\(f.rfilename) doesn't match Hugging Face's hash after the download")
            }
        }

        let repo = try Scanner.inspect(repo: repoDir)
        let expected = Set(meta.siblings.map { "\(meta.sha)/\($0.rfilename)" })
        guard commit == meta.sha else { throw ShelfError.verifyFailed("the SDK downloaded \(commit), not \(meta.sha)") }
        guard repo.health.isOK, expected.isSubset(of: repo.snapshotFiles) else {
            throw ShelfError.verifyFailed("some files of \(meta.sha) are still missing after the download")
        }

        // Merge the verified download into the library copy.
        let merge = try Transfer.backup(repoDir, toHub: libraryHub, cancel: cancel, progress: progress)
        return DownloadOutcome(commit: commit, bytesDownloaded: remaining, prelink: prelink, merge: merge)
    }
}

/// At most a few progress updates per second.
final class Throttle: @unchecked Sendable {
    private var last = Date.distantPast
    func ready() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.2 else { return false }
        last = now
        return true
    }
}
