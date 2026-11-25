import CryptoKit
import Darwin
import Foundation

// MARK: - Which revision to download

public struct RevisionChoice: Sendable, Hashable {
    /// A commit hash, or "main" when nothing on disk says which commit to use.
    public let revision: String
    /// Shown to the user and written to the activity log.
    public let source: String

    public init(revision: String, source: String) { self.revision = revision; self.source = source }

    public var isPinned: Bool { Hub.isCommit(revision) }
    public static let latest = RevisionChoice(revision: "main", source: "latest (main)")
}

/// Commits recorded by LocalLM Lab apps: `~/Library/Application Support/<app>/mlx-pins.json`
/// (or `<app>/LocalLMLab/mlx-pins.json`), written by the SDK's `MLXFilePinStore`.
public enum PinFiles {
    public static func candidates(appSupport: URL? = nil) -> [URL] {
        let fm = FileManager.default
        guard let base = appSupport ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let apps = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        return apps.sorted().flatMap { app in
            [base.appendingPathComponent("\(app)/mlx-pins.json"), base.appendingPathComponent("\(app)/LocalLMLab/mlx-pins.json")]
        }.filter { fm.fileExists(atPath: $0.path) }
    }

    /// repo id -> (commit, "<app> pin"). The first file to pin a repo wins.
    public static func load(appSupport: URL? = nil) -> [String: RevisionChoice] {
        struct Payload: Decodable { var pins: [String: String] }
        var result: [String: RevisionChoice] = [:]
        for url in candidates(appSupport: appSupport) {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { continue }
            var app = url.deletingLastPathComponent()
            if app.lastPathComponent == "LocalLMLab" { app.deleteLastPathComponent() }
            for (repo, rev) in payload.pins where Hub.isCommit(rev) && result[repo] == nil {
                result[repo] = RevisionChoice(revision: rev.lowercased(), source: "\(app.lastPathComponent) pin")
            }
        }
        return result
    }
}

// MARK: - Hugging Face metadata

public struct HubFile: Sendable, Equatable, Decodable {
    public struct LFS: Sendable, Equatable, Decodable {
        public let sha256: String
        public let size: Int64
    }
    public let rfilename: String
    public let blobId: String
    public let size: Int64?
    public let lfs: LFS?

    public init(rfilename: String, blobId: String, size: Int64?, lfs: LFS?) {
        self.rfilename = rfilename; self.blobId = blobId; self.size = size; self.lfs = lfs
    }

    /// The name the HF cache stores this file under in `blobs/`: the SHA-256 for LFS files,
    /// the git blob id otherwise.
    public var blobName: String { lfs?.sha256 ?? blobId }
    public var byteSize: Int64 { lfs?.size ?? size ?? 0 }
}

public struct HubRevision: Sendable, Equatable, Decodable {
    public let sha: String
    public let siblings: [HubFile]
    public init(sha: String, siblings: [HubFile]) { self.sha = sha; self.siblings = siblings }
}

public enum Hub {
    public static func isCommit(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy { $0.isHexDigit }
    }

    /// Extra folders to look for a `token` file in, e.g. the Hugging Face folder the user granted
    /// in the sandbox (`~/.cache/huggingface`).
    nonisolated(unsafe) public static var tokenFolders: [URL] = []

    /// Token for gated models, same places huggingface_hub looks.
    public static var token: String? {
        let env = ProcessInfo.processInfo.environment
        if let t = env["HF_TOKEN"], !t.isEmpty { return t }
        let homes = tokenFolders.map(\.path) + [env["HF_HOME"] ?? Sandbox.realHome + "/.cache/huggingface"]
        for home in homes {
            if let t = (try? String(contentsOfFile: home + "/token", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return t }
        }
        return nil
    }

    /// File list (with blob hashes) for `revision`, which may be a branch name; `sha` is the
    /// commit it resolved to.
    public static func fetchRevision(repoID: String, revision: String) async throws -> HubRevision {
        var comps = URLComponents(string: "https://huggingface.co")!
        comps.percentEncodedPath = "/api/models/\(repoID)/revision/"
            + (revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? revision)
        comps.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw ShelfError.hub("Hugging Face refused access to \(repoID). It may be gated: accept its terms on huggingface.co and save a token with `hf auth login`.")
        case 404: throw ShelfError.hub("Hugging Face has no \(repoID) at revision \(revision).")
        default: throw ShelfError.hub("Hugging Face returned HTTP \(status) for \(repoID).")
        }
        let rev = try JSONDecoder().decode(HubRevision.self, from: data)
        guard isCommit(rev.sha) else { throw ShelfError.hub("Hugging Face didn't return a commit for \(repoID).") }
        return rev
    }
}

// MARK: - Re-linking blobs that are already on disk

public struct PrelinkResult: Sendable, Equatable {
    public var linked = 0
    public var bytesReused: Int64 = 0
    public var missing = 0
    /// Blobs of the right size whose hash doesn't match their name. Delete before re-fetching:
    /// a downloader that finds a blob already present may keep it.
    public var corrupt: [String] = []
    /// Blobs that were checked and linked.
    public var verifiedBlobs: Set<String> = []
}

public enum Prelinker {
    /// For every file of `revision`, if `repo/blobs` already holds its blob, checks the blob's hash
    /// and (re)creates `snapshots/<commit>/<file>` pointing at it. Files whose blob is missing or
    /// doesn't match are left for the downloader. Only ever adds links to verified data, so it's
    /// safe to interrupt.
    @discardableResult
    public static func prelink(
        _ revision: HubRevision,
        repo: URL,
        cancel: CancelToken = CancelToken(),
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) throws -> PrelinkResult {
        let fm = FileManager.default
        let blobs = repo.appendingPathComponent("blobs")
        let snap = repo.appendingPathComponent("snapshots/\(revision.sha)")

        let present = revision.siblings.filter { f in
            let attrs = try? fm.attributesOfItem(atPath: blobs.appendingPathComponent(f.blobName).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == f.byteSize
        }
        let reporter = Reporter(total: present.reduce(0) { $0 + $1.byteSize }, phase: .verifying, sink: progress)

        var result = PrelinkResult()
        var verified = Set<String>()
        for f in revision.siblings {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let link = snap.appendingPathComponent(f.rfilename)
            guard present.contains(f) else { result.missing += 1; continue }
            if !verified.contains(f.blobName) {
                let blob = blobs.appendingPathComponent(f.blobName)
                guard try hashMatches(blob, file: f, cancel: cancel, reporter: reporter) else {
                    result.missing += 1
                    if !result.corrupt.contains(f.blobName) { result.corrupt.append(f.blobName) }
                    continue
                }
                verified.insert(f.blobName)
                result.verifiedBlobs.insert(f.blobName)
                result.bytesReused += f.byteSize
            }
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: link.path)) != nil { try fm.removeItem(at: link) }
            let depth = f.rfilename.split(separator: "/").count - 1
            try fm.createSymbolicLink(atPath: link.path,
                                      withDestinationPath: String(repeating: "../", count: depth + 2) + "blobs/" + f.blobName)
            result.linked += 1
        }
        reporter.flush()
        return result
    }

    /// True when `url` holds exactly the bytes `file` describes.
    public static func verify(_ url: URL, file: HubFile, cancel: CancelToken,
                              progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) throws -> Bool {
        try hashMatches(url, file: file, cancel: cancel, reporter: Reporter(total: file.byteSize, phase: .verifying, sink: progress))
    }

    /// LFS files are named by SHA-256; small files by their git blob id, SHA-1 of "blob <size>\0" + bytes.
    static func hashMatches(_ url: URL, file: HubFile, cancel: CancelToken, reporter: Reporter) throws -> Bool {
        let fd = open(url.path, O_RDONLY)
        // Can't read it (permissions, a drive that just went away): that's an error, not damage.
        guard fd >= 0 else { throw Transfer.posix("Couldn't open", url.path) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let size = Transfer.chunkSize
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        defer { buf.deallocate() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        let isLFS = file.lfs != nil
        if !isLFS { sha1.update(data: Data("blob \(file.byteSize)\0".utf8)) }
        while true {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let n = read(fd, buf, size)
            if n < 0 { if errno == EINTR { continue }; throw Transfer.posix("Couldn't read", url.path) }
            if n == 0 { break }
            let chunk = UnsafeRawBufferPointer(start: buf, count: n)
            if isLFS { sha256.update(bufferPointer: chunk) } else { sha1.update(bufferPointer: chunk) }
            reporter.add(Int64(n))
        }
        let hex = isLFS ? Transfer.hex(sha256.finalize()) : sha1.finalize().map { String(format: "%02x", $0) }.joined()
        return hex == file.blobName.lowercased()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension RevisionChoice {
    /// Which commit to (re)download: the one the library copy is at, else the Mac copy's, else a
    /// LocalLM Lab pin, else the latest on `main`.
    public static func pick(library: RepoInfo?, local: RepoInfo?, pin: RevisionChoice?) -> RevisionChoice {
        if let r = library?.currentRevision, Hub.isCommit(r) { return RevisionChoice(revision: r, source: "library copy") }
        if let r = local?.currentRevision, Hub.isCommit(r) { return RevisionChoice(revision: r, source: "Mac copy") }
        return pin ?? .latest
    }
}
