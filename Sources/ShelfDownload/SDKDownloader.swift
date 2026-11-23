import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import ShelfCore

public struct DownloadOutcome: Sendable {
    /// The commit now in the library.
    public let commit: String
    public let bytesDownloaded: Int64
    public let prelink: PrelinkResult
    public let repo: RepoInfo
}

/// Re-downloads a model straight into the library through the LocalLM SDK:
/// 1. resolve the requested revision to a commit (so a moving `main` can't change mid-way);
/// 2. re-link blobs already on the drive, after checking their hashes, so nothing is fetched twice;
/// 3. `MLXModelProvider(cacheDirectory: library, pinnedRevisions: [repo: commit]).download(repo)`
///    fetches and verifies whatever is still missing and writes the SDK's completion marker;
/// 4. check the result is complete.
public enum SDKDownloader {
    public static func download(
        repoID: String,
        choice: RevisionChoice,
        libraryHub: URL,
        cancel: CancelToken,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> DownloadOutcome {
        let meta = try await Hub.fetchRevision(repoID: repoID, revision: choice.revision)
        if choice.isPinned, meta.sha != choice.revision.lowercased() {
            throw ShelfError.hub("Hugging Face resolved \(choice.revision) to a different commit (\(meta.sha)).")
        }
        let repoDir = libraryHub.appendingPathComponent(RepoName.dirName(forModel: repoID))
        try FileManager.default.createDirectory(at: repoDir.appendingPathComponent("blobs"), withIntermediateDirectories: true)

        let prelink = try await Task.detached(priority: .userInitiated) {
            try Prelinker.prelink(meta, repo: repoDir, cancel: cancel, progress: progress)
        }.value
        if cancel.isCancelled { throw ShelfError.cancelled }
        // A same-named blob that's present would be kept by the SDK's cache instead of the fresh copy.
        for name in prelink.corrupt {
            try FileManager.default.removeItem(at: repoDir.appendingPathComponent("blobs/\(name)"))
        }

        // Space for whatever the SDK still has to fetch.
        var seen = Set<String>()
        let remaining = meta.siblings.filter { f in
            let link = repoDir.appendingPathComponent("snapshots/\(meta.sha)/\(f.rfilename)")
            return !FileManager.default.fileExists(atPath: link.path) && seen.insert(f.blobName).inserted
        }.reduce(Int64(0)) { $0 + $1.byteSize }
        if let free = Transfer.freeSpace(libraryHub), free < remaining + (512 << 20) {
            throw ShelfError.notEnoughSpace(needed: remaining, available: free)
        }

        var commit = meta.sha
        if remaining > 0 || !FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("snapshots/\(meta.sha)/.locallm-download-complete").path) {
            let provider = MLXModelProvider(
                cacheDirectory: libraryHub, pinnedRevisions: [repoID: meta.sha], promptCache: .off)
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
        return DownloadOutcome(commit: commit, bytesDownloaded: remaining, prelink: prelink, repo: repo)
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
