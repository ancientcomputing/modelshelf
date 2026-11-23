import Foundation
import XCTest
@testable import ShelfCore

/// Opt-in end-to-end check against real volumes. Skipped unless both env vars are set:
///   MODELSHELF_E2E_SRC   a real repo folder to read (never modified)
///   MODELSHELF_E2E_DST   an empty scratch folder on the library drive (deleted afterwards)
///   MODELSHELF_E2E_BACK  an empty scratch folder on the Mac (deleted afterwards)
final class CrossVolumeTests: XCTestCase {
    func testRoundTripAcrossVolumes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["MODELSHELF_E2E_SRC"], let d = env["MODELSHELF_E2E_DST"], let b = env["MODELSHELF_E2E_BACK"] else {
            throw XCTSkip("set MODELSHELF_E2E_* to run")
        }
        let fm = FileManager.default
        let src = URL(fileURLWithPath: s), dstHub = URL(fileURLWithPath: d), backHub = URL(fileURLWithPath: b)
        defer { try? fm.removeItem(at: dstHub); try? fm.removeItem(at: backHub) }
        let original = try Scanner.inspect(repo: src)

        var t = Date()
        let copy = try Transfer.copyRepo(src, toHub: dstHub)
        print("E2E copy to drive: \(original.sizeBytes) bytes in \(Date().timeIntervalSince(t))s")
        XCTAssertEqual(copy.health, .ok)
        XCTAssertTrue(copy.covers(original))

        // Simulate the rsync -r damage, then repair: should reuse (clone) every blob.
        let snaps = copy.url.appendingPathComponent("snapshots")
        for rev in try fm.contentsOfDirectory(atPath: snaps.path) {
            let r = snaps.appendingPathComponent(rev)
            try fm.removeItem(at: r); try fm.createDirectory(at: r, withIntermediateDirectories: true)
        }
        XCTAssertFalse(try Scanner.inspect(repo: copy.url).health.isOK)
        final class Box: @unchecked Sendable { var total: Int64 = -1 }
        let box = Box()
        t = Date()
        let repaired = try Transfer.copyRepo(src, toHub: dstHub) { box.total = $0.total }
        print("E2E repair: \(Date().timeIntervalSince(t))s, bytes copied \(box.total / 2)")
        XCTAssertEqual(repaired.health, .ok)
        XCTAssertEqual(box.total, 0)

        t = Date()
        let back = try Transfer.copyRepo(repaired.url, toHub: backHub)
        print("E2E copy back: \(Date().timeIntervalSince(t))s")
        XCTAssertEqual(back.health, .ok)
        XCTAssertEqual(back.blobs, original.blobs)
        XCTAssertTrue(original.covers(back))
        XCTAssertEqual(try Scanner.inspect(repo: src), original, "source must be untouched")
    }
}
