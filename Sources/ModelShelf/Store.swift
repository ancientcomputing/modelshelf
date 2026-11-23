import AppKit
import Observation
import ShelfCore
import ShelfDownload
import SwiftUI

enum Status: Hashable {
    case newOnMac          // only in the cache
    case downloading       // in the cache, still downloading
    case synced            // in both, library has everything
    case libraryOutdated   // in both, library is missing something the Mac has
    case needsRepair       // library copy broken, Mac copy can fix it
    case libraryOnly       // only in the library
    case brokenLibraryOnly // library copy broken, nothing on the Mac to fix it with
    case brokenLocal       // Mac copy broken

    var needsAttention: Bool { [.libraryOutdated, .needsRepair, .brokenLibraryOnly, .brokenLocal].contains(self) }
}

enum JobKind: Sendable {
    case moveToLibrary, copyToLibrary, copyToMac, removeFromMac, deleteFromLibrary, redownload

    func title(_ name: String) -> String {
        switch self {
        case .redownload: "Downloading \(name) into the library"
        case .moveToLibrary: "Moving \(name) to the library"
        case .copyToLibrary: "Copying \(name) to the library"
        case .copyToMac: "Copying \(name) to this Mac"
        case .removeFromMac: "Removing \(name) from this Mac"
        case .deleteFromLibrary: "Deleting \(name) from the library"
        }
    }
}

struct Job: Identifiable, Sendable {
    let id = UUID()
    let dirName: String
    let kind: JobKind
    let title: String
    /// What the activity log calls it, e.g. "Repaired library copy".
    let action: String
    let repoID: String
    /// For `.redownload`: which commit to fetch and why.
    var revision: RevisionChoice? = nil
    /// For removals: the bytes the delete frees, measured before it happens.
    var size: Int64? = nil
    /// The commit the model is at, for the log.
    var currentRevision: String? = nil
}

/// What a finished job reports back for the log.
struct JobResult: Sendable {
    var bytes: Int64?
    var revision: String?
    var detail: String?
}

struct Entry: Identifiable, Hashable {
    let id: String // folder name, e.g. models--org--name
    var local: RepoInfo?
    var library: RepoInfo?

    var repoID: String { RepoName.repoID(id) }
    var org: String { repoID.split(separator: "/").first.map(String.init) ?? "" }
    var name: String { repoID.split(separator: "/").dropFirst().joined(separator: "/") }
    var size: Int64 { local?.sizeBytes ?? library?.sizeBytes ?? 0 }
    var modified: Date { max(local?.modified ?? .distantPast, library?.modified ?? .distantPast) }

    var status: Status {
        if let l = local {
            switch l.health {
            case .downloading: return .downloading
            case .broken: return .brokenLocal
            case .ok:
                guard let lib = library else { return .newOnMac }
                if !lib.health.isOK { return .needsRepair }
                return lib.covers(l) ? .synced : .libraryOutdated
            }
        }
        return library?.health.isOK == true ? .libraryOnly : .brokenLibraryOnly
    }

    /// The one-click action for this row.
    var primaryAction: (label: String, kind: JobKind)? {
        switch status {
        case .newOnMac: ("Move to library", .moveToLibrary)
        case .needsRepair: ("Repair library", .copyToLibrary)
        case .libraryOutdated: ("Update library", .copyToLibrary)
        case .synced: ("Remove from Mac", .removeFromMac)
        case .libraryOnly: ("Copy to Mac", .copyToMac)
        case .brokenLocal: library?.health.isOK == true ? ("Restore from library", .copyToMac) : nil
        case .brokenLibraryOnly: ("Redownload", .redownload)
        case .downloading: nil
        }
    }
}

struct Space { var free: Int64; var total: Int64 }

@MainActor @Observable
final class Store {
    static let defaultLibrary = "/Volumes/Work/models/hub"
    static var defaultCache: String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["HF_HUB_CACHE"] { return p }
        if let h = env["HF_HOME"] { return h + "/hub" }
        return NSHomeDirectory() + "/.cache/huggingface/hub"
    }

    // MODELSHELF_CACHE / MODELSHELF_LIBRARY override saved settings (handy for testing).
    var cachePath: String { didSet { save("cachePath", cachePath) } }
    var libraryPath: String { didSet { save("libraryPath", libraryPath) } }
    var cacheHub: URL { URL(fileURLWithPath: cachePath) }
    var libraryHub: URL { URL(fileURLWithPath: libraryPath) }

    var entries: [Entry] = []
    var libraryAvailable = false
    var macSpace: Space?
    var librarySpace: Space?
    var isScanning = false

    var queue: [Job] = []
    var current: Job?
    var progress: TransferProgress?
    var bytesPerSecond: Double = 0
    var lastError: String?

    /// Newest last. Mirrors the JSON Lines file.
    var activity: [ActivityEntry] = []
    let log = ActivityLog()
    /// Commits recorded by LocalLM Lab apps, by repo id.
    var pins: [String: RevisionChoice] = [:]
    /// Models waiting for the user to confirm a redownload.
    var pendingRedownload: [String] = []

    private var cancelToken: CancelToken?
    private var currentTask: Task<JobResult, Error>?
    private var lastSample: (date: Date, done: Int64)?
    private var observers: [NSObjectProtocol] = []
    private let overridden: Bool

    init() {
        let env = ProcessInfo.processInfo.environment
        overridden = env["MODELSHELF_CACHE"] != nil || env["MODELSHELF_LIBRARY"] != nil
        let d = UserDefaults.standard
        cachePath = env["MODELSHELF_CACHE"] ?? d.string(forKey: "cachePath") ?? Store.defaultCache
        libraryPath = env["MODELSHELF_LIBRARY"] ?? d.string(forKey: "libraryPath") ?? Store.defaultLibrary

        activity = log.load()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refresh() } })
    }

    private func save(_ key: String, _ value: String) {
        if !overridden { UserDefaults.standard.set(value, forKey: key) }
        Task { await refresh() }
    }

    // MARK: Scanning

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let cache = cacheHub, library = libraryHub
        let idle = current == nil
        let result = await Task.detached(priority: .userInitiated) {
            let libOK = FileManager.default.fileExists(atPath: library.path)
            if idle {
                Transfer.cleanupStale(in: cache)
                if libOK { Transfer.cleanupStale(in: library) }
            }
            let space = { (u: URL) -> Space? in
                guard let f = Transfer.freeSpace(u), let t = Transfer.totalSpace(u) else { return nil }
                return Space(free: f, total: t)
            }
            return (Scanner.scan(hub: cache), libOK ? Scanner.scan(hub: library) : [], libOK,
                    space(cache), libOK ? space(library) : nil, PinFiles.load())
        }.value
        pins = result.5

        var byName: [String: Entry] = [:]
        for r in result.0 { byName[r.dirName, default: Entry(id: r.dirName)].local = r }
        for r in result.1 { byName[r.dirName, default: Entry(id: r.dirName)].library = r }
        entries = byName.values.sorted { $0.repoID.localizedStandardCompare($1.repoID) == .orderedAscending }
        libraryAvailable = result.2
        macSpace = result.3
        librarySpace = result.4
    }

    // MARK: Jobs

    func isBusy(_ id: String) -> Bool { current?.dirName == id || queue.contains { $0.dirName == id } }

    func run(_ kind: JobKind, on ids: some Sequence<String>) {
        // Every job reads or writes the library, so the drive must be there.
        guard libraryAvailable else {
            lastError = "Connect the library drive first. Looking for \(libraryPath)."
            return
        }
        for id in ids where !isBusy(id) {
            guard let e = entries.first(where: { $0.id == id }) else { continue }
            var job = Job(dirName: id, kind: kind, title: kind.title(e.repoID), action: actionName(kind, e), repoID: e.repoID,
                          currentRevision: e.library?.currentRevision ?? e.local?.currentRevision)
            switch kind {
            case .removeFromMac: job.size = e.local?.sizeBytes
            case .deleteFromLibrary: job.size = e.library?.sizeBytes
            case .redownload: job.revision = revisionChoice(for: e)
            default: break
            }
            queue.append(job)
        }
        pump()
    }

    private func actionName(_ kind: JobKind, _ e: Entry) -> String {
        switch kind {
        case .moveToLibrary: "Moved to library"
        case .copyToLibrary: e.status == .needsRepair ? "Repaired library copy"
            : e.status == .libraryOutdated ? "Updated library copy" : "Copied to library"
        case .copyToMac: e.status == .brokenLocal ? "Restored Mac copy" : "Copied to Mac"
        case .removeFromMac: "Removed from Mac"
        case .deleteFromLibrary: "Deleted from library"
        case .redownload: "Downloaded into library"
        }
    }

    // MARK: Redownload

    /// The library copy's commit, else the Mac copy's, else a LocalLM Lab pin, else latest.
    func revisionChoice(for e: Entry) -> RevisionChoice {
        RevisionChoice.pick(library: e.library, local: e.local, pin: pins[e.repoID])
    }

    func redownload(_ ids: [String], useLatest: Bool) {
        guard libraryAvailable else {
            lastError = "Connect the library drive first. Looking for \(libraryPath)."
            return
        }
        for id in ids where !isBusy(id) {
            guard let e = entries.first(where: { $0.id == id }) else { continue }
            queue.append(Job(dirName: id, kind: .redownload, title: JobKind.redownload.title(e.repoID),
                             action: "Downloaded into library", repoID: e.repoID,
                             revision: useLatest ? .latest : revisionChoice(for: e)))
        }
        pump()
    }

    /// Drop handler for the sidebar targets.
    func drop(_ ids: [String], toLibrary: Bool) {
        for id in ids {
            guard let e = entries.first(where: { $0.id == id }) else { continue }
            if toLibrary {
                switch e.status {
                case .newOnMac: run(.moveToLibrary, on: [id])
                case .needsRepair, .libraryOutdated: run(.copyToLibrary, on: [id])
                default: break
                }
            } else if e.local == nil || e.status == .brokenLocal, e.library?.health.isOK == true {
                run(.copyToMac, on: [id])
            }
        }
    }

    func cancelCurrent() { cancelToken?.cancel(); currentTask?.cancel() }
    func cancelQueued() { queue.removeAll() }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        progress = nil
        bytesPerSecond = 0
        lastSample = nil
        let token = CancelToken()
        cancelToken = token
        let cache = cacheHub, library = libraryHub
        let report: @Sendable (TransferProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.update(p) }
        }
        let task = Task.detached(priority: .userInitiated) {
            try await Store.perform(job, cache: cache, library: library, token: token, report: report)
        }
        currentTask = task
        let started = Date()
        Task {
            var entry = ActivityEntry(action: job.action, repoID: job.repoID, outcome: .succeeded,
                                      revision: job.currentRevision, revisionSource: job.revision?.source)
            do {
                let r = try await task.value
                entry.bytes = r.bytes
                entry.revision = r.revision ?? entry.revision
                entry.detail = r.detail
            } catch let e where (e as? ShelfError) == .cancelled || e is CancellationError {
                entry.outcome = .cancelled
                entry.revision = job.revision?.revision ?? entry.revision
            } catch {
                entry.outcome = .failed
                entry.revision = job.revision?.revision ?? entry.revision
                entry.detail = error.localizedDescription
                lastError = "\(job.title) failed. \(error.localizedDescription)"
                queue.removeAll() // don't keep going after a failure
            }
            entry.duration = Date().timeIntervalSince(started)
            record(entry)
            current = nil
            progress = nil
            cancelToken = nil
            currentTask = nil
            await refresh()
            pump()
        }
    }

    private func record(_ entry: ActivityEntry) {
        activity.append(entry)
        do { try log.append(entry) } catch { lastError = "Couldn't write the activity log: \(error.localizedDescription)" }
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([log.url])
    }

    private func update(_ p: TransferProgress) {
        progress = p
        let now = Date()
        if let s = lastSample, now.timeIntervalSince(s.date) >= 1 {
            let rate = Double(p.done - s.done) / now.timeIntervalSince(s.date)
            bytesPerSecond = bytesPerSecond == 0 ? rate : bytesPerSecond * 0.6 + rate * 0.4
            lastSample = (now, p.done)
        } else if lastSample == nil {
            lastSample = (now, p.done)
        }
    }

    nonisolated static func perform(_ job: Job, cache: URL, library: URL, token: CancelToken,
                                    report: @escaping @Sendable (TransferProgress) -> Void) async throws -> JobResult {
        let local = cache.appendingPathComponent(job.dirName)
        let lib = library.appendingPathComponent(job.dirName)
        // Copies report copy + verify bytes, so half the total is what was copied.
        final class Last: @unchecked Sendable { var total: Int64 = 0 }
        let last = Last()
        let tracked: @Sendable (TransferProgress) -> Void = { last.total = $0.total; report($0) }
        func copied(_ r: RepoInfo) -> JobResult {
            JobResult(bytes: last.total / 2, revision: r.currentRevision ?? r.snapshots.sorted().joined(separator: ", "))
        }
        switch job.kind {
        case .moveToLibrary: return copied(try Transfer.moveRepo(local, toHub: library, cancel: token, progress: tracked))
        case .copyToLibrary: return copied(try Transfer.copyRepo(local, toHub: library, cancel: token, progress: tracked))
        case .copyToMac: return copied(try Transfer.copyRepo(lib, toHub: cache, cancel: token, progress: tracked))
        case .removeFromMac:
            try Transfer.removeIfCovered(local: local, library: lib)
            return JobResult(bytes: job.size, detail: "freed on this Mac")
        case .deleteFromLibrary:
            try FileManager.default.removeItem(at: lib)
            return JobResult(bytes: job.size, detail: "freed on the library drive")
        case .redownload:
            let out = try await SDKDownloader.download(
                repoID: job.repoID, choice: job.revision ?? .latest, libraryHub: library, cancel: token, progress: report)
            let reused = out.prelink.bytesReused > 0 ? ", reused \(out.prelink.linked) files (\(out.prelink.bytesReused.bytes)) already on the drive" : ""
            return JobResult(bytes: out.bytesDownloaded, revision: out.commit,
                             detail: "downloaded \(out.bytesDownloaded.bytes)\(reused)")
        }
    }

    // MARK: Finder

    func reveal(_ e: Entry) {
        let urls = [e.library?.url, e.local?.url].compactMap { $0 }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
