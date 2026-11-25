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

/// What `Transfer.backup` changed in the destination.
public struct CopyReport: Sendable {
    /// The destination copy afterwards.
    public var repo: RepoInfo
    /// Revisions the source brought that the destination didn't have.
    public var addedRevisions: [String] = []
    /// Revisions only the destination had, left in place.
    public var keptRevisions: [String] = []
    /// Refs whose destination value was kept although the source's differs, e.g. ["main": commit].
    public var keptRefs: [String: String] = [:]
    /// Destination blobs that failed their hash check and were replaced with the source's.
    public var replacedBlobs: [String] = []
    /// Refs the destination had that pointed at a revision it didn't fully hold, and now follow the
    /// source: name -> the old value.
    public var replacedRefs: [String: String] = [:]
    /// Snapshot links that were missing their blob or pointed elsewhere, and were fixed.
    public var fixedLinks = 0
    public var bytesCopied: Int64 = 0

    public init(repo: RepoInfo) { self.repo = repo }
}

public enum Transfer {
    static let chunkSize = 8 << 20
    static let stagingPrefix = ".modelshelf-staging-"
    static let oldPrefix = ".modelshelf-old-"

    /// Copies a repo folder into `dstHub`. Never removes anything the destination already has:
    ///
    /// * No copy there yet: the copy is built in a hidden staging folder, verified, then moved into
    ///   place, so a failure or cancel leaves nothing behind.
    /// * A copy is already there (an older backup, another Mac's revisions, a broken backup): the
    ///   source is merged into it. Missing files are added; files it already holds are checked
    ///   against their hash and kept. A file is replaced only when it fails that check (it's
    ///   damaged), or a link of the source's revision is missing or points elsewhere. Revisions,
    ///   refs and files only the destination has are left alone. Each new file is written to the
    ///   staging folder, verified, then renamed into place.
    ///
    /// Every copied file is verified by SHA-256 against the source. Refs such as `main` keep their
    /// destination value unless the destination's points at a revision it doesn't fully hold.
    @discardableResult
    public static func copyRepo(
        _ src: URL,
        toHub dstHub: URL,
        cancel: CancelToken = CancelToken(),
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) throws -> RepoInfo {
        try backup(src, toHub: dstHub, cancel: cancel, progress: progress).repo
    }

    /// `copyRepo`, reporting what changed in the destination.
    public static func backup(
        _ src: URL,
        toHub dstHub: URL,
        cancel: CancelToken = CancelToken(),
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) throws -> CopyReport {
        let fm = FileManager.default
        let info = try Scanner.inspect(repo: src)
        switch info.health {
        case .ok: break
        case .downloading: throw ShelfError.sourceNotReady("it's still downloading")
        case .broken(let reason): throw ShelfError.sourceNotReady(reason)
        }

        try fm.createDirectory(at: dstHub, withIntermediateDirectories: true)
        let final = dstHub.appendingPathComponent(info.dirName)
        let existing = fm.fileExists(atPath: final.path) ? try Scanner.inspect(repo: final) : nil
        if existing?.health == .downloading {
            // Something is writing into it right now; merging could race the downloader.
            throw ShelfError.destinationBusy("the copy there is still downloading")
        }

        let staging = newStaging(in: dstHub)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) } // only ever our own temporary files

        // A new copy is assembled inside staging and moved into place at the end; an existing copy
        // is merged into directly, with each new file staged first.
        let target = existing == nil ? staging.appendingPathComponent(info.dirName) : final
        let blobs = target.appendingPathComponent("blobs")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)

        // 1. Which blobs the destination already holds intact.
        var report = CopyReport(repo: info)
        let candidates = info.blobs.filter { existing?.blobs[$0.key] == $0.value }
        let toCopyIfAllGood = info.blobs.filter { candidates[$0.key] == nil }
        let reporter = Reporter(total: candidates.values.reduce(0, +) + toCopyIfAllGood.values.reduce(0, +) * 2,
                                phase: candidates.isEmpty ? .copying : .verifying, sink: progress)
        var damaged: [String: Int64] = [:]
        for (name, size) in candidates.sorted(by: { $0.key < $1.key }) {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let ok = try blobMatches(blobs.appendingPathComponent(name), name: name, size: size,
                                     source: src.appendingPathComponent("blobs/\(name)"), cancel: cancel, reporter: reporter)
            if !ok { damaged[name] = size }
        }
        // Blobs present with the wrong size are damaged too (a blob's name is its hash).
        for (name, size) in toCopyIfAllGood where existing?.blobs[name] != nil { damaged[name] = size }
        report.replacedBlobs = damaged.keys.sorted()
        let toCopy = info.blobs.filter { candidates[$0.key] == nil || damaged[$0.key] != nil }
        let bytesToCopy = toCopy.values.reduce(0, +)
        report.bytesCopied = bytesToCopy

        if let free = freeSpace(dstHub), free < bytesToCopy + (512 << 20) {
            throw ShelfError.notEnoughSpace(needed: bytesToCopy, available: free)
        }

        // 2. Copy each missing or damaged blob to staging, verify it, then rename it into place.
        reporter.phase(.copying)
        for (name, _) in toCopy.sorted(by: { $0.key < $1.key }) {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let from = src.appendingPathComponent("blobs/\(name)")
            let temp = staging.appendingPathComponent("blob-\(UUID().uuidString)")
            let expected = try streamCopy(from, to: temp, cancel: cancel, reporter: reporter)
            reporter.phase(.verifying)
            guard try hashFile(temp, cancel: cancel, reporter: reporter) == expected else {
                throw ShelfError.verifyFailed("blob \(name) doesn't match the source")
            }
            // The source's own file must hold what its name says, or a damaged source would
            // overwrite (or be added next to) good data.
            guard try nameMatches(temp, name: name, sha256: expected, cancel: cancel) != false else {
                throw ShelfError.sourceDamaged(String(name.prefix(12)))
            }
            reporter.phase(.copying)
            // rename(2) atomically replaces a damaged blob; a missing one is simply added.
            guard Darwin.rename(temp.path, blobs.appendingPathComponent(name).path) == 0 else {
                throw posix("Couldn't move into place", blobs.appendingPathComponent(name).path)
            }
        }

        // 3. Everything else: snapshot links, loose files, markers, refs.
        guard let en = fm.enumerator(atPath: src.path) else { throw ShelfError.notFound(src.path) }
        while let rel = en.nextObject() as? String {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let parts = rel.split(separator: "/")
            if parts.first == "blobs" { continue }
            let from = src.appendingPathComponent(rel)
            let to = target.appendingPathComponent(rel)
            let have = try? fm.attributesOfItem(atPath: to.path) // doesn't follow links
            switch try fm.attributesOfItem(atPath: from.path)[.type] as? FileAttributeType {
            case .typeDirectory?:
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            case .typeSymbolicLink?:
                let dest = try fm.destinationOfSymbolicLink(atPath: from.path)
                if have?[.type] as? FileAttributeType == .typeSymbolicLink,
                   (try? fm.destinationOfSymbolicLink(atPath: to.path)) == dest {
                    continue
                }
                switch have?[.type] as? FileAttributeType {
                case nil:
                    break
                case .typeSymbolicLink?:
                    // Same revision, same file name: the link must point at the same blob. A link
                    // that points elsewhere (usually at a missing blob) is fixed.
                    try fm.removeItem(at: to)
                    report.fixedLinks += 1
                case .typeRegular?:
                    continue // a real file where the source has a link (e.g. `rsync -L`): it's data, keep it
                default:
                    throw ShelfError.io("\(to.path) is a folder where the source has a link")
                }
                try fm.createSymbolicLink(atPath: to.path, withDestinationPath: dest)
            case .typeRegular?:
                if parts.count == 2, parts[0] == "refs" { continue } // below
                if have == nil { try fm.copyItem(at: from, to: to) } // keep the destination's own files
            default:
                continue // sockets, pipes etc. don't belong in a cache
            }
        }

        // 4. Refs: keep the destination's unless it points at a revision it doesn't fully hold.
        let merged = try Scanner.inspect(repo: target)
        for (name, value) in info.refs {
            let ref = target.appendingPathComponent("refs/\(name)")
            if let mine = existing?.refs[name], mine != value,
               merged.snapshots.contains(mine), Scanner.revisionIsComplete(repo: target, revision: mine) {
                report.keptRefs[name] = mine
                continue
            }
            if existing?.refs[name] == value { continue }
            if let old = existing?.refs[name] { report.replacedRefs[name] = old }
            try fm.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = staging.appendingPathComponent("ref-\(UUID().uuidString)")
            try Data(value.utf8).write(to: temp)
            guard Darwin.rename(temp.path, ref.path) == 0 else { throw posix("Couldn't write", ref.path) }
        }

        // 5. The destination must now hold everything the source does, intact.
        let result = try Scanner.inspect(repo: target)
        guard result.covers(info) else {
            throw ShelfError.verifyFailed("the copy doesn't contain everything in the source")
        }
        for rev in info.snapshots where !Scanner.revisionIsComplete(repo: target, revision: rev) {
            throw ShelfError.verifyFailed("revision \(rev) isn't complete in the copy")
        }
        reporter.flush()

        if existing == nil {
            try fm.moveItem(at: target, to: final)
        }
        report.repo = try Scanner.inspect(repo: final)
        report.addedRevisions = info.snapshots.subtracting(existing?.snapshots ?? []).sorted()
        report.keptRevisions = (existing?.snapshots ?? []).subtracting(info.snapshots).sorted()
        return report
    }

    /// True when the blob at `url` holds the bytes its name says. Hugging Face names large files by
    /// their SHA-256 and small ones by their git blob id (SHA-1 of "blob <size>\0" + bytes); for any
    /// other name the bytes are compared with `source` by SHA-256.
    static func blobMatches(_ url: URL, name: String, size: Int64, source: URL,
                            cancel: CancelToken, reporter: Reporter) throws -> Bool {
        let hexDigits = name.allSatisfy(\.isHexDigit)
        if hexDigits, name.count == 64 {
            return try hashFile(url, cancel: cancel, reporter: reporter) == name.lowercased()
        }
        if hexDigits, name.count == 40 {
            return try gitBlobID(url, size: size, cancel: cancel, reporter: reporter) == name.lowercased()
        }
        return try hashFile(url, cancel: cancel, reporter: reporter) == hashFile(source, cancel: cancel, reporter: nil)
    }

    /// Whether a file's bytes match its hash-named blob name: true or false for SHA-256 (64 hex
    /// digits, using the `sha256` already computed) and git blob ids (40), nil for other names.
    static func nameMatches(_ url: URL, name: String, sha256: String, cancel: CancelToken) throws -> Bool? {
        guard name.allSatisfy(\.isHexDigit) else { return nil }
        if name.count == 64 { return sha256 == name.lowercased() }
        if name.count == 40 {
            let size = ((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?.int64Value ?? 0
            return try gitBlobID(url, size: size, cancel: cancel, reporter: nil) == name.lowercased()
        }
        return nil
    }

    static func gitBlobID(_ url: URL, size: Int64, cancel: CancelToken, reporter: Reporter?) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posix("Couldn't open", url.path) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        defer { buf.deallocate() }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        while true {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let n = read(fd, buf, chunkSize)
            if n < 0 { if errno == EINTR { continue }; throw posix("Couldn't read", url.path) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            reporter?.add(Int64(n))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A new hidden staging folder name in `hub` (not created). Cleanup removes abandoned ones.
    public static func newStaging(in hub: URL) -> URL {
        hub.appendingPathComponent(stagingPrefix + UUID().uuidString)
    }

    /// Deletes `local` only if `library` is healthy, holds everything `local` does, and every
    /// library file the Mac copy relies on passes its hash check (read from the drive, so a file
    /// damaged without changing size is caught).
    /// Returns this Mac's refs whose value differs from the library's (e.g. ["main": commit]), so
    /// the caller can record what `main` meant here.
    @discardableResult
    public static func removeIfCovered(
        local: URL,
        library: URL,
        cancel: CancelToken = CancelToken(),
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) throws -> [String: String] {
        let l = try Scanner.inspect(repo: local)
        if l.health == .downloading {
            throw ShelfError.libraryDoesNotCover("this Mac's copy is still downloading")
        }
        guard let lib = try? Scanner.inspect(repo: library) else {
            throw ShelfError.libraryDoesNotCover("there's no library copy")
        }
        guard local.resolvingSymlinksInPath().standardizedFileURL != library.resolvingSymlinksInPath().standardizedFileURL else {
            throw ShelfError.libraryDoesNotCover("the library and the Mac copy are the same folder")
        }
        if case .broken(let r) = lib.health { throw ShelfError.libraryDoesNotCover(r) }
        guard lib.health.isOK else { throw ShelfError.libraryDoesNotCover("it's not ready") }
        guard lib.covers(l) else { throw ShelfError.libraryDoesNotCover("it's missing files the Mac copy has") }
        for rev in l.snapshots where !Scanner.revisionIsComplete(repo: library, revision: rev) {
            throw ShelfError.libraryDoesNotCover("revision \(rev.prefix(7)) isn't complete there")
        }
        let reporter = Reporter(total: l.blobs.values.reduce(0, +), phase: .verifying, sink: progress)
        for (name, size) in l.blobs.sorted(by: { $0.key < $1.key }) {
            if cancel.isCancelled { throw ShelfError.cancelled }
            guard try blobMatches(library.appendingPathComponent("blobs/\(name)"), name: name, size: size,
                                  source: local.appendingPathComponent("blobs/\(name)"), cancel: cancel, reporter: reporter) else {
                throw ShelfError.libraryDoesNotCover("a file there is damaged (\(name.prefix(12))…). Use Repair library first")
            }
        }
        // Real files in this Mac's snapshots (e.g. a config edited in place) must match the library's.
        let fm = FileManager.default
        for rel in l.snapshotFiles.sorted() {
            if cancel.isCancelled { throw ShelfError.cancelled }
            let mine = local.appendingPathComponent("snapshots/\(rel)")
            guard (try? fm.attributesOfItem(atPath: mine.path))?[.type] as? FileAttributeType == .typeRegular,
                  !(rel as NSString).lastPathComponent.hasPrefix(".") else { continue }
            let theirs = library.appendingPathComponent("snapshots/\(rel)")
            guard fm.fileExists(atPath: theirs.path),
                  try hashFile(mine, cancel: cancel, reporter: nil) == hashFile(theirs, cancel: cancel, reporter: nil) else {
                throw ShelfError.libraryDoesNotCover("\(rel) on this Mac differs from the library's")
            }
        }
        if cancel.isCancelled { throw ShelfError.cancelled }
        try fm.removeItem(at: local)
        return l.refs.filter { lib.refs[$0.key] != $0.value }
    }

    /// Removes staging folders abandoned by interrupted transfers. Only ones untouched for a day:
    /// a newer one may belong to a copy still running in another window or on another Mac that
    /// shares the drive. Staging folders only ever hold Model Shelf's own temporary files.
    ///
    /// `.modelshelf-old-*` folders are never removed: versions up to 1.0.3 parked the original copy
    /// there while swapping in a new one, so after a crash one may be the only copy of a model.
    public static func cleanupStale(in hub: URL, olderThan age: TimeInterval = 24 * 3600, now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: hub.path)) ?? [] where name.hasPrefix(stagingPrefix) {
            let url = hub.appendingPathComponent(name)
            guard let modified = newestModification(in: url), now.timeIntervalSince(modified) > age else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// The latest modification date of a folder or anything in it.
    static func newestModification(in url: URL) -> Date? {
        let fm = FileManager.default
        var newest = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let en = fm.enumerator(atPath: url.path) {
            while let rel = en.nextObject() as? String {
                if let d = (try? fm.attributesOfItem(atPath: url.appendingPathComponent(rel).path))?[.modificationDate] as? Date,
                   d > (newest ?? .distantPast) { newest = d }
            }
        }
        return newest
    }

    /// `.modelshelf-old-*` folders in `hub` left by versions up to 1.0.3 (see `cleanupStale`).
    public static func parkedCopies(in hub: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: hub.path)) ?? [])
            .filter { $0.hasPrefix(oldPrefix) }.map { hub.appendingPathComponent($0) }
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
