import CryptoKit
import Foundation
import XCTest
@testable import ShelfCore

final class TransferTests: XCTestCase {
    var root: URL!
    var cache: URL!
    var library: URL!
    let fm = FileManager.default
    let dir = "models--acme--tiny-4bit"

    override func setUp() {
        root = fm.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString)")
        cache = root.appendingPathComponent("cache/hub")
        library = root.appendingPathComponent("library/hub")
        try! fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try! fm.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDown() { try? fm.removeItem(at: root) }

    /// Builds a repo laid out like huggingface_hub does: blobs + relative snapshot symlinks.
    @discardableResult
    func makeRepo(in hub: URL, bigBytes: Int = 3 << 20) throws -> URL {
        let repo = hub.appendingPathComponent(dir)
        let rev = "abc123"
        let snap = repo.appendingPathComponent("snapshots/\(rev)")
        try fm.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: snap.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try rev.write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)

        var big = Data(count: bigBytes)
        big.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: i &* 31) } }
        try big.write(to: repo.appendingPathComponent("blobs/bigblob"))
        try Data("{\"a\":1}".utf8).write(to: repo.appendingPathComponent("blobs/smallblob"))

        try fm.createSymbolicLink(atPath: snap.appendingPathComponent("model.safetensors").path,
                                  withDestinationPath: "../../blobs/bigblob")
        try fm.createSymbolicLink(atPath: snap.appendingPathComponent("sub/config.json").path,
                                  withDestinationPath: "../../../blobs/smallblob")
        try Data().write(to: snap.appendingPathComponent(".download-complete"))
        return repo
    }

    func testScanParsesNameAndHealth() throws {
        try makeRepo(in: cache)
        try fm.createDirectory(at: cache.appendingPathComponent("blobs"), withIntermediateDirectories: true) // stray non-repo dir
        let repos = Scanner.scan(hub: cache)
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos[0].repoID, "acme/tiny-4bit")
        XCTAssertEqual(repos[0].health, .ok)
        XCTAssertEqual(repos[0].blobs.count, 2)
        XCTAssertEqual(repos[0].snapshots, ["abc123"])
    }

    func testCopyPreservesSymlinksAndKeepsSource() throws {
        let src = try makeRepo(in: cache)
        let result = try Transfer.copyRepo(src, toHub: library)
        XCTAssertEqual(result.health, .ok)
        let link = library.appendingPathComponent("\(dir)/snapshots/abc123/model.safetensors").path
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), "../../blobs/bigblob")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: link)), // follows the link
                       try Data(contentsOf: src.appendingPathComponent("blobs/bigblob")))
        XCTAssertTrue(fm.fileExists(atPath: src.path))
        XCTAssertNoStaging(library)
    }

    func testRepairsBackupWithMissingSnapshotLinks() throws {
        // What `rsync -r` (no -l) produces: blobs copied, symlinks skipped.
        let src = try makeRepo(in: cache)
        let broken = library.appendingPathComponent(dir)
        try fm.createDirectory(at: broken.appendingPathComponent("snapshots/abc123/sub"), withIntermediateDirectories: true)
        try fm.copyItem(at: src.appendingPathComponent("blobs"), to: broken.appendingPathComponent("blobs"))
        XCTAssertEqual(try Scanner.inspect(repo: broken).health, .broken("the snapshot links are missing"))

        let report = try Transfer.backup(src, toHub: library)
        XCTAssertEqual(try Scanner.inspect(repo: broken).health, .ok)
        XCTAssertEqual(report.bytesCopied, 0, "blobs already in the library should be checked and reused, not copied")
        XCTAssertEqual(report.replacedBlobs, [])
        XCTAssertNoStaging(library)
    }

    func testRemoveLocalRequiresCompleteLibraryCopy() throws {
        let src = try makeRepo(in: cache)
        XCTAssertThrowsError(try Transfer.removeIfCovered(local: src, library: library.appendingPathComponent(dir)))

        try Transfer.copyRepo(src, toHub: library)
        try fm.removeItem(at: library.appendingPathComponent("\(dir)/blobs/smallblob"))
        XCTAssertThrowsError(try Transfer.removeIfCovered(local: src, library: library.appendingPathComponent(dir)))
        XCTAssertTrue(fm.fileExists(atPath: src.path))

        try Transfer.copyRepo(src, toHub: library)
        try Transfer.removeIfCovered(local: src, library: library.appendingPathComponent(dir))
        XCTAssertFalse(fm.fileExists(atPath: src.path))
    }

    func testMarkerOnlySnapshotIsBrokenAndNeverCoversTheMac() throws {
        // The real-world damage: blobs copied, links skipped, only a hidden marker file left.
        let src = try makeRepo(in: cache)
        let lib = library.appendingPathComponent(dir)
        try fm.createDirectory(at: lib.appendingPathComponent("snapshots/abc123"), withIntermediateDirectories: true)
        try fm.copyItem(at: src.appendingPathComponent("blobs"), to: lib.appendingPathComponent("blobs"))
        try Data().write(to: lib.appendingPathComponent("snapshots/abc123/.download-complete"))

        XCTAssertEqual(try Scanner.inspect(repo: lib).health, .broken("the snapshot links are missing"))
        XCTAssertFalse(try Scanner.inspect(repo: lib).covers(Scanner.inspect(repo: src)))
        XCTAssertThrowsError(try Transfer.removeIfCovered(local: src, library: lib))
        XCTAssertTrue(fm.fileExists(atPath: src.path))
    }

    func testMissingOneSnapshotLinkDoesNotCover() throws {
        let src = try makeRepo(in: cache)
        let copy = try Transfer.copyRepo(src, toHub: library)
        try fm.removeItem(at: copy.url.appendingPathComponent("snapshots/abc123/sub/config.json"))
        XCTAssertEqual(try Scanner.inspect(repo: copy.url).health, .ok, "still loads, just incomplete")
        XCTAssertThrowsError(try Transfer.removeIfCovered(local: src, library: copy.url))
        XCTAssertTrue(fm.fileExists(atPath: src.path))
    }

    func testRefusesSourceStillDownloading() throws {
        let src = try makeRepo(in: cache)
        try Data("x".utf8).write(to: src.appendingPathComponent("blobs/zzz.incomplete"))
        XCTAssertThrowsError(try Transfer.copyRepo(src, toHub: library)) { e in
            XCTAssertEqual(e as? ShelfError, .sourceNotReady("it's still downloading"))
        }
        XCTAssertTrue(fm.fileExists(atPath: src.path))
        XCTAssertFalse(fm.fileExists(atPath: library.appendingPathComponent(dir).path))
    }

    func testCancelLeavesNothingBehind() throws {
        let src = try makeRepo(in: cache, bigBytes: 64 << 20)
        let token = CancelToken()
        XCTAssertThrowsError(try Transfer.copyRepo(src, toHub: library, cancel: token) { p in
            if p.done > 0 { token.cancel() }
        }) { e in XCTAssertEqual(e as? ShelfError, .cancelled) }
        XCTAssertTrue(fm.fileExists(atPath: src.path))
        XCTAssertFalse(fm.fileExists(atPath: library.appendingPathComponent(dir).path))
        XCTAssertNoStaging(library)
    }

    func testDanglingLinkIsBroken() throws {
        let src = try makeRepo(in: cache)
        try fm.removeItem(at: src.appendingPathComponent("blobs/smallblob"))
        XCTAssertEqual(try Scanner.inspect(repo: src).health, .broken("1 snapshot file point to missing data"))
        XCTAssertThrowsError(try Transfer.copyRepo(src, toHub: library))
    }

    // MARK: Backups never remove what the destination already has

    /// Adds revision `rev` to `repo` with one file of its own, and points refs/main at it.
    @discardableResult
    func addRevision(_ rev: String, to repo: URL, file: String = "extra.json",
                     content: String = "only here", setMain: Bool = true) throws -> String {
        let blob = "blob-\(rev)"
        try Data(content.utf8).write(to: repo.appendingPathComponent("blobs/\(blob)"))
        let snap = repo.appendingPathComponent("snapshots/\(rev)")
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: snap.appendingPathComponent(file).path, withDestinationPath: "../../blobs/\(blob)")
        if setMain { try rev.write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8) }
        return blob
    }

    func testBackupFromSecondMacKeepsTheLibrarysOtherRevision() throws {
        // The library was backed up from Mac 1 at def456; this Mac has abc123.
        let lib = try makeRepo(in: library)
        try fm.removeItem(at: lib.appendingPathComponent("snapshots/abc123"))
        let onlyOnDrive = try addRevision("def456", to: lib)
        let mac = try makeRepo(in: cache)
        XCTAssertFalse(try Scanner.inspect(repo: lib).covers(Scanner.inspect(repo: mac)), "shows Update library")

        let report = try Transfer.backup(mac, toHub: library)
        let after = try Scanner.inspect(repo: lib)
        XCTAssertEqual(after.snapshots, ["abc123", "def456"])
        XCTAssertNotNil(after.blobs[onlyOnDrive])
        XCTAssertTrue(Scanner.revisionIsComplete(repo: lib, revision: "def456"))
        XCTAssertTrue(Scanner.revisionIsComplete(repo: lib, revision: "abc123"))
        XCTAssertEqual(after.refs["main"], "def456", "main still means what it meant on the drive")
        XCTAssertEqual(report.addedRevisions, ["abc123"])
        XCTAssertEqual(report.keptRevisions, ["def456"])
        XCTAssertEqual(report.keptRefs, ["main": "def456"])
        XCTAssertTrue(after.covers(try Scanner.inspect(repo: mac)), "now fully backed up")
        XCTAssertNoStaging(library)

        // And Mac 1 backing up again doesn't take abc123 away.
        let mac1 = root.appendingPathComponent("mac1/hub")
        try fm.createDirectory(at: mac1, withIntermediateDirectories: true)
        try Transfer.backup(lib, toHub: mac1) // restore everything to Mac 1
        try fm.removeItem(at: mac1.appendingPathComponent("\(dir)/snapshots/abc123"))
        try Transfer.backup(mac1.appendingPathComponent(dir), toHub: library)
        XCTAssertEqual(try Scanner.inspect(repo: lib).snapshots, ["abc123", "def456"])
    }

    func testRestoreToMacKeepsTheMacsOwnRevision() throws {
        let mac = try makeRepo(in: cache)
        try addRevision("fff999", to: mac, setMain: false) // downloaded here, never backed up
        try fm.removeItem(at: mac.appendingPathComponent("blobs/smallblob")) // abc123 is damaged on the Mac
        XCTAssertEqual(try Scanner.inspect(repo: mac).health, .broken("1 snapshot file point to missing data"))
        let lib = try makeRepo(in: library)

        try Transfer.backup(lib, toHub: cache) // "Restore from library"
        let after = try Scanner.inspect(repo: mac)
        XCTAssertEqual(after.health, .ok)
        XCTAssertEqual(after.snapshots, ["abc123", "fff999"])
        XCTAssertTrue(Scanner.revisionIsComplete(repo: mac, revision: "fff999"))
    }

    func testRepairKeepsARevisionOnlyTheLibraryHasEvenIfItIsBroken() throws {
        let mac = try makeRepo(in: cache)
        let lib = library.appendingPathComponent(dir)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        try fm.copyItem(at: mac.appendingPathComponent("blobs"), to: lib.appendingPathComponent("blobs"))
        try fm.createDirectory(at: lib.appendingPathComponent("snapshots/abc123"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.appendingPathComponent("refs"), withIntermediateDirectories: true)
        // def456 is only on the drive, and one of its files is missing: the drive copy is broken.
        try addRevision("def456", to: lib, setMain: false)
        try fm.createSymbolicLink(atPath: lib.appendingPathComponent("snapshots/def456/gone.bin").path,
                                  withDestinationPath: "../../blobs/never-copied")

        let report = try Transfer.backup(mac, toHub: library) // "Repair library"
        XCTAssertTrue(Scanner.revisionIsComplete(repo: lib, revision: "abc123"), "repaired")
        XCTAssertTrue(fm.fileExists(atPath: lib.appendingPathComponent("snapshots/def456/extra.json").path))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: lib.appendingPathComponent("snapshots/def456/gone.bin").path),
                        "left as it was, for Redownload to fix")
        XCTAssertEqual(report.keptRevisions, ["def456"])
    }

    func testDamagedFileInTheDestinationIsReplacedNotTrusted() throws {
        let src = try makeRepo(in: cache)
        let lib = try Transfer.copyRepo(src, toHub: library).url
        // Same size, different bytes: a size check alone would keep it.
        var bad = try Data(contentsOf: lib.appendingPathComponent("blobs/bigblob"))
        bad[1000] ^= 0xFF
        try bad.write(to: lib.appendingPathComponent("blobs/bigblob"))

        let report = try Transfer.backup(src, toHub: library)
        XCTAssertEqual(report.replacedBlobs, ["bigblob"])
        XCTAssertEqual(try Data(contentsOf: lib.appendingPathComponent("blobs/bigblob")),
                       try Data(contentsOf: src.appendingPathComponent("blobs/bigblob")))
    }

    func testRealFilesWhereLinksBelongAreKept() throws {
        // `rsync -L` copies the files the links point to instead of the links.
        let src = try makeRepo(in: cache)
        let lib = library.appendingPathComponent(dir)
        try fm.createDirectory(at: lib.appendingPathComponent("snapshots/abc123/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        let real = lib.appendingPathComponent("snapshots/abc123/model.safetensors")
        try fm.copyItem(at: src.appendingPathComponent("blobs/bigblob"), to: real)

        try Transfer.backup(src, toHub: library)
        XCTAssertEqual((try fm.attributesOfItem(atPath: real.path))[.type] as? FileAttributeType, .typeRegular)
        XCTAssertTrue(Scanner.revisionIsComplete(repo: lib, revision: "abc123"))
    }

    func testRefusesADestinationThatIsStillDownloading() throws {
        let src = try makeRepo(in: cache)
        let lib = try makeRepo(in: library)
        try fm.removeItem(at: lib.appendingPathComponent("snapshots/abc123/sub/config.json"))
        try Data("partial".utf8).write(to: lib.appendingPathComponent("blobs/xyz.incomplete"))
        let before = try fm.subpathsOfDirectory(atPath: lib.path).sorted()

        XCTAssertThrowsError(try Transfer.backup(src, toHub: library)) { e in
            XCTAssertEqual(e as? ShelfError, .destinationBusy("the copy there is still downloading"))
        }
        XCTAssertEqual(try fm.subpathsOfDirectory(atPath: lib.path).sorted(), before, "nothing touched")
        XCTAssertNoStaging(library)
    }

    func testRemoveFromMacRefusesWhenALibraryFileIsDamaged() throws {
        let mac = try makeRepo(in: cache)
        let lib = try Transfer.copyRepo(mac, toHub: library).url
        var bad = try Data(contentsOf: lib.appendingPathComponent("blobs/bigblob"))
        bad[10] ^= 0xFF // same size, wrong bytes
        try bad.write(to: lib.appendingPathComponent("blobs/bigblob"))
        XCTAssertThrowsError(try Transfer.removeIfCovered(local: mac, library: lib))
        XCTAssertTrue(fm.fileExists(atPath: mac.path), "the Mac copy is the only good one")

        try Transfer.backup(mac, toHub: library) // Repair library
        try Transfer.removeIfCovered(local: mac, library: lib)
        XCTAssertFalse(fm.fileExists(atPath: mac.path))
    }

    func testRemoveFromMacRefusesWhileTheMacCopyIsDownloading() throws {
        let mac = try makeRepo(in: cache)
        let lib = try Transfer.copyRepo(mac, toHub: library).url
        try Data("partial".utf8).write(to: mac.appendingPathComponent("blobs/new.incomplete")) // started after the scan
        XCTAssertThrowsError(try Transfer.removeIfCovered(local: mac, library: lib))
        XCTAssertTrue(fm.fileExists(atPath: mac.appendingPathComponent("blobs/new.incomplete").path))
    }

    func testRemoveFromMacRefusesWhenAFileWasEditedInPlace() throws {
        let mac = try makeRepo(in: cache)
        let lib = try Transfer.copyRepo(mac, toHub: library).url
        let config = mac.appendingPathComponent("snapshots/abc123/sub/config.json")
        try fm.removeItem(at: config) // editors replace the link with a real file
        try Data("{\"a\":2}".utf8).write(to: config)
        XCTAssertThrowsError(try Transfer.removeIfCovered(local: mac, library: lib))
        XCTAssertTrue(fm.fileExists(atPath: config.path))
    }

    func testBackupRefusesASourceFileThatFailsItsHashName() throws {
        // A real cache names blobs by their SHA-256; the Mac's file is damaged, the drive's is good.
        let mac = try makeRepo(in: cache)
        let good = Data("good weights".utf8)
        let name = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()
        try good.write(to: mac.appendingPathComponent("blobs/\(name)"))
        try fm.createSymbolicLink(atPath: mac.appendingPathComponent("snapshots/abc123/w.bin").path,
                                  withDestinationPath: "../../blobs/\(name)")
        let lib = try Transfer.copyRepo(mac, toHub: library).url
        try fm.removeItem(at: lib.appendingPathComponent("snapshots/abc123/w.bin")) // so the drive needs an update

        // Same size, rotted: the drive's file passes its check and is kept; nothing is copied over it.
        try Data("bad weights!".utf8).write(to: mac.appendingPathComponent("blobs/\(name)"))
        let report = try Transfer.backup(mac, toHub: library)
        XCTAssertEqual(report.replacedBlobs, [])
        XCTAssertEqual(try Data(contentsOf: lib.appendingPathComponent("blobs/\(name)")), good)

        // Truncated: the sizes differ, and the Mac's file is the one that fails its name.
        try fm.removeItem(at: lib.appendingPathComponent("snapshots/abc123/w.bin"))
        try Data("bad".utf8).write(to: mac.appendingPathComponent("blobs/\(name)"))
        XCTAssertThrowsError(try Transfer.backup(mac, toHub: library)) { e in
            XCTAssertEqual(e as? ShelfError, .sourceDamaged(String(name.prefix(12))))
        }
        XCTAssertEqual(try Data(contentsOf: lib.appendingPathComponent("blobs/\(name)")), good, "the good copy survives")
    }

    func testRemoveFromMacRefusesWhenLibraryIsTheSameFolder() throws {
        let mac = try makeRepo(in: cache)
        XCTAssertThrowsError(try Transfer.removeIfCovered(local: mac, library: mac))
        XCTAssertTrue(fm.fileExists(atPath: mac.path))
    }

    func testCancelledMergeLeavesTheDestinationsFilesInPlace() throws {
        let src = try makeRepo(in: cache, bigBytes: 64 << 20)
        let lib = try makeRepo(in: library, bigBytes: 1 << 20)
        try fm.removeItem(at: lib.appendingPathComponent("snapshots/abc123"))
        try fm.removeItem(at: lib.appendingPathComponent("blobs/bigblob"))
        try addRevision("def456", to: lib)
        let before = try fm.subpathsOfDirectory(atPath: lib.path).sorted()

        let token = CancelToken()
        XCTAssertThrowsError(try Transfer.backup(src, toHub: library, cancel: token) { p in
            if p.done > 0 { token.cancel() }
        }) { e in XCTAssertEqual(e as? ShelfError, .cancelled) }
        let after = Set(try fm.subpathsOfDirectory(atPath: lib.path))
        XCTAssertTrue(Set(before).isSubset(of: after), "a cancelled backup only ever adds")
        XCTAssertTrue(Scanner.revisionIsComplete(repo: lib, revision: "def456"))
        XCTAssertNoStaging(library)
    }

    func testCleanupLeavesRecentStagingAndParkedCopies() throws {
        let recent = library.appendingPathComponent(".modelshelf-staging-recent")
        let abandoned = library.appendingPathComponent(".modelshelf-staging-abandoned")
        let parked = library.appendingPathComponent(".modelshelf-old-1234")
        for u in [recent, abandoned, parked] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: abandoned.path)
        try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: parked.path)

        Transfer.cleanupStale(in: library)
        XCTAssertTrue(fm.fileExists(atPath: recent.path), "may be another Mac's copy in progress")
        XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
        XCTAssertTrue(fm.fileExists(atPath: parked.path), "may be the only copy of a model")
    }

    func XCTAssertNoStaging(_ hub: URL, file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? fm.contentsOfDirectory(atPath: hub.path)) ?? []
        XCTAssertFalse(names.contains { $0.hasPrefix(".modelshelf") }, "leftover: \(names)", file: file, line: line)
    }
}
