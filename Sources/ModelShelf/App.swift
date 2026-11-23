import AppKit
import SwiftUI

@main
struct ModelShelfApp: App {
    @State private var store = Store()

    init() {
        // Running as a bare SwiftPM binary: make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Model Shelf", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 540)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh() } }.keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

struct SettingsView: View {
    @Bindable var store: Store

    var body: some View {
        Form {
            Section {
                PathRow(title: "Library", detail: "Holds all your models. Usually on the external drive.",
                        path: $store.libraryPath, reset: Store.defaultLibrary)
                PathRow(title: "Hugging Face cache", detail: "Where downloads land. Set by HF_HUB_CACHE or HF_HOME.",
                        path: $store.cachePath, reset: Store.defaultCache)
            } footer: {
                Text("Both folders are hub folders: they contain models--org--name folders.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}

struct PathRow: View {
    let title: String
    let detail: String
    @Binding var path: String
    let reset: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if path != reset { Button("Reset") { path = reset }.controlSize(.small) }
                Button("Choose…") { choose() }.controlSize(.small)
            }
            Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
