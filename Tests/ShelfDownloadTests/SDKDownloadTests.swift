import Foundation
import XCTest
import ShelfCore
@testable import ShelfDownload

/// Opt-in, uses the network: set MODELSHELF_NET_E2E=<scratch dir>. Downloads a ~12 MB public test
/// repo through the LocalLM SDK, then exercises the repair paths.
final class SDKDownloadTests: XCTestCase {
    let repoID = "hf-internal-testing/tiny-random-gpt2"
    let commit = "71034c5d8bde858ff824298bdedc65515b97d2b9"

    func testDownloadRepairAndCorruption() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MODELSHELF_NET_E2E"] else {
            throw XCTSkip("set MODELSHELF_NET_E2E to run")
        }
        let fm = FileManager.default
        let hub = URL(fileURLWithPath: dir).appendingPathComponent("hub-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: hub) }
        let choice = RevisionChoice(revision: commit, source: "test pin")

        // 1. Fresh download.
        let first = try await SDKDownloader.download(repoID: repoID, choice: choice, libraryHub: hub, cancel: CancelToken()) { _ in }
        print("NET fresh: commit \(first.commit) downloaded \(first.bytesDownloaded) reused \(first.prelink.linked)")
        XCTAssertEqual(first.commit, commit)
        XCTAssertEqual(first.repo.health, RepoHealth.ok)
        XCTAssertGreaterThan(first.bytesDownloaded, 1_000_000)
        let snap = first.repo.url.appendingPathComponent("snapshots/\(commit)")
        XCTAssertTrue(fm.fileExists(atPath: snap.appendingPathComponent(".locallm-download-complete").path))

        // 2. The rsync -r damage: links gone, only the marker left. Should relink, download nothing.
        for name in try fm.contentsOfDirectory(atPath: snap.path) where name != ".locallm-download-complete" {
            try fm.removeItem(at: snap.appendingPathComponent(name))
        }
        XCTAssertFalse(try Scanner.inspect(repo: first.repo.url).health.isOK)
        let repaired = try await SDKDownloader.download(repoID: repoID, choice: choice, libraryHub: hub, cancel: CancelToken()) { _ in }
        print("NET repair: downloaded \(repaired.bytesDownloaded) reused \(repaired.prelink.linked) files \(repaired.prelink.bytesReused) bytes")
        XCTAssertEqual(repaired.repo.health, RepoHealth.ok)
        XCTAssertEqual(repaired.prelink.missing, 0)
        XCTAssertEqual(repaired.bytesDownloaded, 0)

        // 3. A corrupt blob (same size) must not be linked; the SDK fetches that file again.
        for name in try fm.contentsOfDirectory(atPath: snap.path) where name != ".locallm-download-complete" {
            try fm.removeItem(at: snap.appendingPathComponent(name))
        }
        let blobs = first.repo.url.appendingPathComponent("blobs")
        let weights = "9ccb1b43b02b0ce538d412ed16bd7dcee4e91651741334a3cb3caecb33cc604c" // tf_model.h5
        var bytes = try Data(contentsOf: blobs.appendingPathComponent(weights))
        bytes[1000] ^= 0xFF
        try bytes.write(to: blobs.appendingPathComponent(weights))
        let fixed = try await SDKDownloader.download(repoID: repoID, choice: choice, libraryHub: hub, cancel: CancelToken()) { _ in }
        print("NET corrupt: downloaded \(fixed.bytesDownloaded) missing-before \(fixed.prelink.missing)")
        XCTAssertEqual(fixed.prelink.missing, 1)
        XCTAssertEqual(fixed.prelink.corrupt, [weights])
        XCTAssertEqual(fixed.bytesDownloaded, 8_462_256, "only the corrupt file is fetched")
        XCTAssertEqual(fixed.repo.health, RepoHealth.ok)
        let again = try Data(contentsOf: blobs.appendingPathComponent(weights))
        XCTAssertNotEqual(again, bytes, "corrupt blob was replaced")
    }
}
