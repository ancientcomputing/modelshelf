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

    func testMoveDeletesSourceOnlyAfterCopy() throws {
        let src = try makeRepo(in: cache)
        try Transfer.moveRepo(src, toHub: library)
        XCTAssertFalse(fm.fileExists(atPath: src.path))
        XCTAssertEqual(try Scanner.inspect(repo: library.appendingPathComponent(dir)).health, .ok)
    }

    func testRepairsBackupWithMissingSnapshotLinks() throws {
        // What `rsync -r` (no -l) produces: blobs copied, symlinks skipped.
        let src = try makeRepo(in: cache)
        let broken = library.appendingPathComponent(dir)
        try fm.createDirectory(at: broken.appendingPathComponent("snapshots/abc123/sub"), withIntermediateDirectories: true)
        try fm.copyItem(at: src.appendingPathComponent("blobs"), to: broken.appendingPathComponent("blobs"))
        XCTAssertEqual(try Scanner.inspect(repo: broken).health, .broken("the snapshot links are missing"))

        final class Box: @unchecked Sendable { var last: TransferProgress? }
        let box = Box()
        try Transfer.copyRepo(src, toHub: library) { p in box.last = p }
        XCTAssertEqual(try Scanner.inspect(repo: broken).health, .ok)
        XCTAssertEqual(box.last?.total, 0, "blobs already in the library should be reused, not copied")
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
        XCTAssertThrowsError(try Transfer.moveRepo(src, toHub: library)) { e in
            XCTAssertEqual(e as? ShelfError, .sourceNotReady("it's still downloading"))
        }
        XCTAssertTrue(fm.fileExists(atPath: src.path))
        XCTAssertFalse(fm.fileExists(atPath: library.appendingPathComponent(dir).path))
    }

    func testCancelLeavesNothingBehind() throws {
        let src = try makeRepo(in: cache, bigBytes: 64 << 20)
        let token = CancelToken()
        XCTAssertThrowsError(try Transfer.moveRepo(src, toHub: library, cancel: token) { p in
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

    func XCTAssertNoStaging(_ hub: URL, file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? fm.contentsOfDirectory(atPath: hub.path)) ?? []
        XCTAssertFalse(names.contains { $0.hasPrefix(".modelshelf") }, "leftover: \(names)", file: file, line: line)
    }
}
