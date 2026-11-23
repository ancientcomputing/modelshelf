import AppKit
import ShelfCore

/// Demo mode for App Store screenshots: `MODELSHELF_DEMO=<root>` points the app at a library made by
/// packaging/screenshots/make_demo_library.py, with fixed disk space numbers, its own activity log,
/// no LocalLM Lab pins and a fixed window size. Nothing is saved to the user's settings.
/// `MODELSHELF_DEMO_SHOT` picks what the window shows; packaging/screenshots/capture.sh sets both.
enum Demo {
    enum Shot: String {
        case library    // all models
        case moving     // all models, a move to the library in progress
        case attention  // the Needs attention filter
        case redownload // the redownload confirmation
        case activity   // the activity log
        case setup      // first-run folder setup
    }

    static let root: URL? = ProcessInfo.processInfo.environment["MODELSHELF_DEMO"].map { URL(fileURLWithPath: $0) }
    static var isActive: Bool { root != nil }
    static let shot = Shot(rawValue: ProcessInfo.processInfo.environment["MODELSHELF_DEMO_SHOT"] ?? "") ?? .library

    static var cacheHub: String { path("Mac/.cache/huggingface/hub") }
    static var libraryHub: String { path("ModelDrive/models/hub") }
    /// Where the folder pickers open: choosing the folder shown picks the right one.
    static var cachePickerStart: URL { URL(fileURLWithPath: path("Mac/.cache/huggingface")) }
    static var libraryPickerStart: URL { URL(fileURLWithPath: path("ModelDrive/models")) }
    static var activityLog: URL { URL(fileURLWithPath: path("activity.jsonl")) }

    /// A 1 TB Mac that's getting full and a 4 TB drive.
    static let macSpace = Space(free: 148_300_000_000, total: 994_660_000_000)
    static let librarySpace = Space(free: 2_870_000_000_000, total: 4_000_000_000_000)

    /// Window size in points. On a 1x display the capture is this many pixels; capture.sh centres it
    /// on a 1440 x 900 background.
    static let windowSize = NSSize(width: 1200, height: 740)

    static var initialFilter: Filter {
        switch shot {
        case .attention, .redownload: .attention
        case .activity: .activity
        default: .all
        }
    }

    private static func path(_ rel: String) -> String { root!.appendingPathComponent(rel).path }

    /// Sizes and centres the main window once it exists.
    @MainActor static func sizeWindow() {
        guard isActive else { return }
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
            w.setContentSize(windowSize)
            w.center()
            NSApp.activate()
        }
    }
}

extension String {
    /// `/Users/me/x` as `~/x`, using the real home folder (the sandbox's home is its container).
    var tildePath: String {
        let home = Sandbox.realHome
        return hasPrefix(home + "/") ? "~" + dropFirst(home.count) : self
    }
}
