// Lists the on-screen windows of a process, for capture.sh:  windows <pid>
// One line per window, front to back: "<id> <x> <y> <width> <height> <owner>".
// Also lists the sandbox's open panel, which another process draws for the app.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: windows <pid>\n".data(using: .utf8)!)
    exit(2)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let ownerPID = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
    // Layer 0: normal windows. 8: a modal panel, which is where the open panel goes once it's active.
    guard [0, 8].contains(w[kCGWindowLayer as String] as? Int ?? -1),
          ownerPID == pid || owner.contains("Open and Save Panel"),
          let b = w[kCGWindowBounds as String] as? [String: Double],
          let id = w[kCGWindowNumber as String] as? Int else { continue }
    print(id, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!), owner.replacingOccurrences(of: " ", with: "_"))
}
