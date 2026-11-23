import CryptoKit
import Darwin
import Foundation

public struct TransferProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case copying = "Copying", verifying = "Verifying", downloading = "Downloading" }
    public var phase: Phase
    public var done: Int64
    public var total: Int64

    public init(phase: Phase, done: Int64, total: Int64) {
        self.phase = phase; self.done = done; self.total = total
    }
}

public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Throttles progress callbacks to a few per second.
final class Reporter: @unchecked Sendable {
    private(set) var progress: TransferProgress
    private var last = Date.distantPast
    private let sink: @Sendable (TransferProgress) -> Void

    init(total: Int64, phase: TransferProgress.Phase = .copying, sink: @escaping @Sendable (TransferProgress) -> Void) {
        progress = TransferProgress(phase: phase, done: 0, total: total)
        self.sink = sink
        sink(progress)
    }

    func phase(_ p: TransferProgress.Phase) { progress.phase = p; flush() }

    func add(_ n: Int64) {
        progress.done += n
        let now = Date()
        if now.timeIntervalSince(last) >= 0.2 { last = now; sink(progress) }
    }

    func flush() { last = Date(); sink(progress) }
}

public enum Transfer {
    static let chunkSize = 8 << 20
    static let stagingPrefix = ".modelshelf-staging-"
    static let oldPrefix = ".modelshelf-old-"

    /// Copies a repo folder into `dstHub`, preserving symlinks, then verifies every copied blob
    /// by SHA-256 against the source. If `dstHub` already has a copy of this repo (e.g. a broken
    /// backup), blobs it already holds with the right size are reused (cloned on APFS) instead of
    /// copied again. The result is assembled in a hidden staging folder and swapped in only after
    /// verification, so a failure or cancel never leaves a half-written repo behind.
    @discardableResult
    public static func copyRepo(
        _ src: URL,
        toHub dstHub: URL,
        cancel: CancelToken = CancelToken(),
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) throws -> RepoInfo {
        let fm = FileManager.default
        let info = try Scanner.inspect(repo: src)
        switch info.health {
        case .ok: break
        case .downloading: throw ShelfError.sourceNotReady("it's still downloading")
        case .broken(let reason): throw ShelfError.sourceNotReady(reason)
        }

        try fm.createDirectory(at: dstHub, withIntermediateDirectories: true)
        let final = dstHub.appendingPathComponent(info.dirName)
        let existing = try? Scanner.inspect(repo: final)
        let reusable = Set(info.blobs.compactMap { name, size in existing?.blobs[name] == size ? name : nil })
        let bytesToCopy = info.blobs.filter { !reusable.contains($0.key) }.values.reduce(0, +)

        if let free = freeSpace(dstHub), free < bytesToCopy + (512 << 20) {
            throw ShelfError.notEnoughSpace(needed: bytesToCopy, available: free)
        }

        let reporter = Reporter(total: bytesToCopy * 2, sink: progress)
        let staging = newStaging(in: dstHub)
        do {
            // 1. Copy the tree.
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            var sourceHashes: [String: String] = [:]
            guard let en = fm.enumerator(atPath: src.path) else { throw ShelfError.notFound(src.path) }
            while let rel = en.nextObject() as? String {
                if cancel.isCancelled { throw ShelfError.cancelled }
                let from = src.appendingPathComponent(rel)
                let to = staging.appendingPathComponent(rel)
                let attrs = try fm.attributesOfItem(atPath: from.path)
                switch attrs[.type] as? FileAttributeType {
                case .typeDirectory?:
                    try fm.createDirectory(at: to, withIntermediateDirectories: true)
                case .typeSymbolicLink?:
                    let dest = try fm.destinationOfSymbolicLink(atPath: from.path)
                    try fm.createSymbolicLink(atPath: to.path, withDestinationPath: dest)
                case .typeRegular?:
                    let parts = rel.split(separator: "/")
                    if parts.count == 2, parts[0] == "blobs" {
                        let name = String(parts[1])
                        if reusable.contains(name), let existing {
                            try clone(existing.url.appendingPathComponent(rel), to: to)
                        } else {
                            sourceHashes[name] = try streamCopy(from, to: to, cancel: cancel, reporter: reporter)
                        }
                    } else {
                        try fm.copyItem(at: from, to: to)
                    }
                default:
                    continue // sockets, pipes etc. don't belong in a cache
                }
            }

            // 2. Verify.
            reporter.phase(.verifying)
            for (name, expected) in sourceHashes {
                if cancel.isCancelled { throw ShelfError.cancelled }
                let actual = try hashFile(staging.appendingPathComponent("blobs/\(name)"), cancel: cancel, reporter: reporter)
                guard actual == expected else { throw ShelfError.verifyFailed("blob \(name) doesn't match the source") }
            }
            let copied = try Scanner.inspect(repo: staging)
            guard copied.health.isOK else {
                if case .broken(let r) = copied.health { throw ShelfError.verifyFailed(r) }
                throw ShelfError.verifyFailed("the copy isn't complete")
            }
            guard copied.blobs == info.blobs else { throw ShelfError.verifyFailed("the blob list doesn't match the source") }
            reporter.flush()

            // 3. Swap into place.
            try swapIntoPlace(staging, final: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return try Scanner.inspect(repo: final)
    }

    /// Replaces `final` with `staging`; if that fails, the old `final` is put back.
    static func swapIntoPlace(_ staging: URL, final: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: final.path) else { return try fm.moveItem(at: staging, to: final) }
        let old = final.deletingLastPathComponent().appendingPathComponent(oldPrefix + UUID().uuidString)
        try fm.moveItem(at: final, to: old)
        do {
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.moveItem(at: old, to: final)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    /// Recreates `src`'s tree inside the existing folder `dst`: folders, symlinks as symlinks,
    /// files cloned (instant on APFS when both are on one volume). Skips unfinished downloads.
    static func cloneTree(_ src: URL, into dst: URL) throws {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: src.path) else { return }
        while let rel = en.nextObject() as? String {
            if rel.hasSuffix(".incomplete") { continue }
            let from = src.appendingPathComponent(rel), to = dst.appendingPathComponent(rel)
            switch try fm.attributesOfItem(atPath: from.path)[.type] as? FileAttributeType {
            case .typeDirectory?: try fm.createDirectory(at: to, withIntermediateDirectories: true)
            case .typeSymbolicLink?:
                try fm.createSymbolicLink(atPath: to.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: from.path))
            case .typeRegular?: try clone(from, to: to)
            default: continue
            }
        }
    }

    static func newStaging(in hub: URL) -> URL {
        hub.appendingPathComponent(stagingPrefix + UUID().uuidString)
    }

    /// Copy + verify, then delete the source.
    @discardableResult
    public static func moveRepo(
        _ src: URL,
        toHub dstHub: URL,
        cancel: CancelToken = CancelToken(),
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) throws -> RepoInfo {
        let before = try Scanner.inspect(repo: src)
        let result = try copyRepo(src, toHub: dstHub, cancel: cancel, progress: progress)
        guard result.health.isOK, result.covers(before) else {
            throw ShelfError.verifyFailed("the destination doesn't contain everything in the source")
        }
        try FileManager.default.removeItem(at: src)
        return result
    }

    /// Deletes `local` only if `library` is healthy and holds everything `local` does.
    public static func removeIfCovered(local: URL, library: URL) throws {
        let l = try Scanner.inspect(repo: local)
        guard let lib = try? Scanner.inspect(repo: library) else {
            throw ShelfError.libraryDoesNotCover("there's no library copy")
        }
        if case .broken(let r) = lib.health { throw ShelfError.libraryDoesNotCover(r) }
        guard lib.health.isOK else { throw ShelfError.libraryDoesNotCover("it's not ready") }
        guard lib.covers(l) else { throw ShelfError.libraryDoesNotCover("it's missing files the Mac copy has") }
        try FileManager.default.removeItem(at: local)
    }

    /// Removes leftovers from interrupted transfers.
    public static func cleanupStale(in hub: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: hub.path)) ?? []
        where name.hasPrefix(stagingPrefix) || name.hasPrefix(oldPrefix) {
            try? fm.removeItem(at: hub.appendingPathComponent(name))
        }
    }

    public static func freeSpace(_ url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    public static func totalSpace(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }

    // MARK: - File primitives

    static func clone(_ from: URL, to: URL) throws {
        if Darwin.clonefile(from.path, to.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: from, to: to) // not APFS, or different volume
    }

    static func posix(_ what: String, _ path: String) -> ShelfError {
        .io("\(what) \(path): \(String(cString: strerror(errno)))")
    }

    /// Copies bytes without the page cache (so 40 GB doesn't evict everything else) and returns
    /// the SHA-256 of what was read.
    static func streamCopy(_ from: URL, to: URL, cancel: CancelToken, reporter: Reporter) throws -> String {
        let inFD = open(from.path, O_RDONLY)
        guard inFD >= 0 else { throw posix("Couldn't open", from.path) }
        defer { close(inFD) }
        _ = fcntl(inFD, F_NOCACHE, 1)

        let outFD = open(to.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard outFD >= 0 else { throw posix("Couldn't create", to.path) }
        var outClosed = false
        defer { if !outClosed { close(outFD) } }
        _ = fcntl(outFD, F_NOCACHE, 1)

        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        defer { buf.deallocate() }
        var hasher = SHA256()
        while true {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let n = read(inFD, buf, chunkSize)
            if n < 0 { if errno == EINTR { continue }; throw posix("Couldn't read", from.path) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            var off = 0
            while off < n {
                let w = write(outFD, buf + off, n - off)
                if w < 0 { if errno == EINTR { continue }; throw posix("Couldn't write", to.path) }
                off += w
            }
            reporter.add(Int64(n))
        }
        if fcntl(outFD, F_FULLFSYNC) != 0, fsync(outFD) != 0 { throw posix("Couldn't flush", to.path) }
        outClosed = true
        if close(outFD) != 0 { throw posix("Couldn't close", to.path) }
        return hex(hasher.finalize())
    }

    static func hashFile(_ url: URL, cancel: CancelToken, reporter: Reporter?) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posix("Couldn't open", url.path) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        defer { buf.deallocate() }
        var hasher = SHA256()
        while true {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let n = read(fd, buf, chunkSize)
            if n < 0 { if errno == EINTR { continue }; throw posix("Couldn't read", url.path) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            reporter?.add(Int64(n))
        }
        return hex(hasher.finalize())
    }

    static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }
}
