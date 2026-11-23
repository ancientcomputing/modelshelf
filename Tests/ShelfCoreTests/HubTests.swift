import CryptoKit
import Foundation
import XCTest
@testable import ShelfCore

final class HubTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUp() {
        root = fm.temporaryDirectory.appendingPathComponent("shelf-hub-\(UUID().uuidString)")
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? fm.removeItem(at: root) }

    func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    func gitBlobID(_ d: Data) -> String {
        Insecure.SHA1.hash(data: Data("blob \(d.count)\0".utf8) + d).map { String(format: "%02x", $0) }.joined()
    }

    /// A library copy damaged like the real ones: blobs present, snapshot holds only the marker.
    func makeBrokenRepo() throws -> (URL, HubRevision) {
        let weights = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let config = Data("{\"model_type\":\"tiny\"}".utf8)
        let commit = String(repeating: "ab", count: 20)
        let rev = HubRevision(sha: commit, siblings: [
            HubFile(rfilename: "config.json", blobId: gitBlobID(config), size: Int64(config.count), lfs: nil),
            HubFile(rfilename: "weights/model.safetensors", blobId: "unused",
                    size: Int64(weights.count), lfs: .init(sha256: sha256(weights), size: Int64(weights.count))),
            HubFile(rfilename: "tokenizer.json", blobId: "0000000000000000000000000000000000000000", size: 10, lfs: nil),
        ])
        let repo = root.appendingPathComponent("models--acme--tiny")
        try fm.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("snapshots/\(commit)"), withIntermediateDirectories: true)
        try config.write(to: repo.appendingPathComponent("blobs/\(gitBlobID(config))"))
        try weights.write(to: repo.appendingPathComponent("blobs/\(sha256(weights))"))
        try Data().write(to: repo.appendingPathComponent("snapshots/\(commit)/.locallm-download-complete"))
        return (repo, rev)
    }

    func testPrelinkLinksVerifiedBlobsAndLeavesMissingOnes() throws {
        let (repo, rev) = try makeBrokenRepo()
        let r = try Prelinker.prelink(rev, repo: repo)
        XCTAssertEqual(r.linked, 2)
        XCTAssertEqual(r.missing, 1, "tokenizer.json has no blob")
        let link = repo.appendingPathComponent("snapshots/\(rev.sha)/weights/model.safetensors").path
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), "../../../blobs/\(rev.siblings[1].blobName)")
        XCTAssertTrue(fm.fileExists(atPath: link), "link resolves")
        XCTAssertTrue(try Scanner.inspect(repo: repo).snapshotFiles.contains("\(rev.sha)/config.json"))
    }

    func testPrelinkSkipsCorruptBlob() throws {
        let (repo, rev) = try makeBrokenRepo()
        let blob = repo.appendingPathComponent("blobs/\(rev.siblings[1].blobName)")
        var bytes = try Data(contentsOf: blob)
        bytes[100] ^= 0xFF // same size, different content
        try bytes.write(to: blob)
        let r = try Prelinker.prelink(rev, repo: repo)
        XCTAssertEqual(r.linked, 1)
        XCTAssertEqual(r.corrupt, [rev.siblings[1].blobName])
        XCTAssertFalse(fm.fileExists(atPath: repo.appendingPathComponent("snapshots/\(rev.sha)/weights/model.safetensors").path))
    }

    func testActivityLogRoundTrip() throws {
        let log = ActivityLog(url: root.appendingPathComponent("sub/activity.jsonl"))
        try log.append(ActivityEntry(action: "Downloaded", repoID: "acme/tiny", outcome: .succeeded,
                                     revision: "abc", revisionSource: "LocalLM Lab pin", bytes: 42))
        try log.append(ActivityEntry(action: "Removed from Mac", repoID: "acme/tiny", outcome: .failed, detail: "nope"))
        let entries = log.load()
        XCTAssertEqual(entries.map(\.action), ["Downloaded", "Removed from Mac"])
        XCTAssertEqual(entries[0].revisionSource, "LocalLM Lab pin")
        XCTAssertEqual(entries[1].outcome, .failed)
    }

    func testPinFilesAndRevisionChoice() throws {
        let app = root.appendingPathComponent("LocalLM Lab")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let pin = String(repeating: "c", count: 40)
        try Data("{\"pins\":{\"acme/tiny\":\"\(pin)\",\"acme/bad\":\"main\"}}".utf8)
            .write(to: app.appendingPathComponent("mlx-pins.json"))
        let pins = PinFiles.load(appSupport: root)
        XCTAssertEqual(pins["acme/tiny"], RevisionChoice(revision: pin, source: "LocalLM Lab pin"))
        XCTAssertNil(pins["acme/bad"], "non-commit pins are ignored")

        let (repo, rev) = try makeBrokenRepo()
        let lib = try Scanner.inspect(repo: repo)
        XCTAssertEqual(RevisionChoice.pick(library: lib, local: nil, pin: pins["acme/tiny"]).source, "library copy")
        XCTAssertEqual(RevisionChoice.pick(library: lib, local: nil, pin: nil).revision, rev.sha)
        XCTAssertEqual(RevisionChoice.pick(library: nil, local: nil, pin: pins["acme/tiny"]).revision, pin)
        XCTAssertEqual(RevisionChoice.pick(library: nil, local: nil, pin: nil), .latest)
    }
}
