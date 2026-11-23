import Foundation
import XCTest
@testable import ShelfCore

final class FolderAccessTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUp() {
        root = fm.temporaryDirectory.appendingPathComponent("shelf-access-\(UUID().uuidString)")
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? fm.removeItem(at: root) }

    func testHubForPickedFolder() throws {
        // Picked ~/.cache/huggingface: use hub/ inside it.
        let hf = root.appendingPathComponent("huggingface")
        try fm.createDirectory(at: hf.appendingPathComponent("hub/models--a--b"), withIntermediateDirectories: true)
        XCTAssertEqual(HubFolder.hub(forPicked: hf).lastPathComponent, "hub")
        // Picked the hub itself.
        XCTAssertEqual(HubFolder.hub(forPicked: hf.appendingPathComponent("hub")).lastPathComponent, "hub")
        // A folder full of repos named anything is a hub, even if it also has a hub/ child.
        let lib = root.appendingPathComponent("library")
        try fm.createDirectory(at: lib.appendingPathComponent("models--x--y"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.appendingPathComponent("hub"), withIntermediateDirectories: true)
        XCTAssertEqual(HubFolder.hub(forPicked: lib), lib)
        // An empty new folder is used as is.
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(HubFolder.hub(forPicked: empty), empty)
    }

    func testBookmarkRoundTripAndMissingFolder() throws {
        let dir = root.appendingPathComponent("granted")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let folder = GrantedFolder(bookmark: nil)
        XCTAssertFalse(folder.isGranted)
        try folder.grant(dir)
        XCTAssertTrue(folder.isAccessible)

        // A new launch resolves the saved bookmark.
        let relaunched = GrantedFolder(bookmark: folder.bookmark)
        XCTAssertEqual(relaunched.url?.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)

        // Folder gone (like an ejected drive): stays granted, not accessible, resolves again later.
        let moved = root.appendingPathComponent("moved-away")
        try fm.moveItem(at: dir, to: moved)
        relaunched.invalidateIfMissing()
        XCTAssertTrue(relaunched.isGranted)
        try fm.moveItem(at: moved, to: dir)
        relaunched.resolve()
        XCTAssertTrue(relaunched.isAccessible)
    }

    func testTokenFromGrantedFolder() throws {
        let hf = root.appendingPathComponent("hf")
        try fm.createDirectory(at: hf, withIntermediateDirectories: true)
        try "hf_test123\n".write(to: hf.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        Hub.tokenFolders = [hf]
        defer { Hub.tokenFolders = [] }
        if ProcessInfo.processInfo.environment["HF_TOKEN"] == nil {
            XCTAssertEqual(Hub.token, "hf_test123")
        }
    }
}
