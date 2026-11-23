import AppKit
import ShelfCore
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
                .onAppear { Demo.sizeWindow() }
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
                        path: store.libraryHub.path,
                        choose: { store.choose(.library) },
                        reset: Sandbox.isActive || store.libraryPath == Store.defaultLibrary && !store.libraryGranted
                            ? nil : { store.resetFolder(.library) })
                PathRow(title: "Hugging Face cache",
                        detail: Sandbox.isActive ? "Where downloads land. Choose ~/.cache/huggingface so gated models can use your saved token."
                                                 : "Where downloads land. Set by HF_HUB_CACHE or HF_HOME.",
                        path: store.cacheHub.path,
                        choose: { store.choose(.cache) },
                        reset: Sandbox.isActive || store.cachePath == Store.defaultCache && !store.cacheGranted
                            ? nil : { store.resetFolder(.cache) })
            } footer: {
                Text("Both are hub folders: they contain models--org--name folders. You can also choose the folder that contains a hub folder.")
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
    let path: String
    let choose: () -> Void
    let reset: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let reset { Button("Reset", action: reset).controlSize(.small) }
                Button("Choose…", action: choose).controlSize(.small)
            }
            Text(path.tildePath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
