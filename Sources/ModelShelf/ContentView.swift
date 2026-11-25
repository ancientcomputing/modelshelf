import AppKit
import ShelfCore
import SwiftUI

enum Filter: String, CaseIterable, Identifiable {
    case all, library, mac, new, attention, activity
    var id: Self { self }
    static var modelFilters: [Filter] { [.all, .library, .mac, .new, .attention] }

    var title: String {
        switch self {
        case .all: "All models"
        case .library: "Library"
        case .mac: "On this Mac"
        case .new: "New downloads"
        case .attention: "Needs attention"
        case .activity: "Activity"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .library: "externaldrive"
        case .mac: "laptopcomputer"
        case .new: "tray.and.arrow.down"
        case .attention: "exclamationmark.triangle"
        case .activity: "clock.arrow.circlepath"
        }
    }

    func includes(_ e: Entry) -> Bool {
        switch self {
        case .all: true
        case .library: e.library != nil
        case .mac: e.local != nil
        case .new: e.status == .newOnMac || e.status == .downloading
        case .attention: e.status.needsAttention
        case .activity: false
        }
    }
}

struct ContentView: View {
    let store: Store
    @State private var filter: Filter? = Demo.isActive ? Demo.initialFilter : .all
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\Entry.repoID)]
    @State private var pendingDelete: [Entry] = []

    private var rows: [Entry] {
        let f = filter ?? .all
        return store.entries
            .filter { f.includes($0) }
            .filter { search.isEmpty || $0.repoID.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        if store.showSetup {
            FolderSetupView(store: store)
        } else {
            main
        }
    }

    private var main: some View {
        NavigationSplitView {
            Sidebar(store: store, filter: $filter)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                if filter == .activity {
                    ActivityView(store: store, search: search)
                } else {
                    StorageHeader(store: store)
                    Banners(store: store)
                    ModelTable(store: store, rows: rows, selection: $selection, sortOrder: $sortOrder, pendingDelete: $pendingDelete)
                }
                if store.current != nil { JobBar(store: store) }
            }
            .navigationTitle((filter ?? .all).title)
            .navigationSubtitle(filter == .activity ? "\(store.activity.count) events"
                                : "\(rows.count) models · \(rows.reduce(0) { $0 + $1.size }.bytes)")
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter models")
        .toolbar {
            ToolbarItem {
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isScanning)
            }
            ToolbarItem {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
        .task { await store.refresh() }
        .alert("Something went wrong", isPresented: .init(
            get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .confirmationDialog(deleteTitle, isPresented: .init(
            get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }
        )) {
            Button("Delete from library", role: .destructive) {
                store.run(.deleteFromLibrary, on: pendingDelete.map(\.id))
                pendingDelete = []
            }
        } message: {
            Text(deleteMessage)
        }
        .confirmationDialog(redownloadTitle, isPresented: .init(
            get: { !store.pendingRedownload.isEmpty }, set: { if !$0 { store.pendingRedownload = [] } }
        )) {
            let ids = store.pendingRedownload
            let anyPinned = redownloadEntries.contains { store.revisionChoice(for: $0).isPinned }
            Button(anyPinned ? "Download pinned revision\(ids.count == 1 ? "" : "s")" : "Download latest") {
                store.redownload(ids, useLatest: false); store.pendingRedownload = []
            }
            if anyPinned {
                Button("Download latest instead") { store.redownload(ids, useLatest: true); store.pendingRedownload = [] }
            }
        } message: {
            Text(redownloadMessage)
        }
    }

    private var redownloadEntries: [Entry] {
        store.entries.filter { store.pendingRedownload.contains($0.id) }
    }

    private var redownloadTitle: String {
        let e = redownloadEntries
        return e.count == 1 ? "Download \(e[0].repoID) into the library?" : "Download \(e.count) models into the library?"
    }

    private var redownloadMessage: String {
        let lines = redownloadEntries.map { e -> String in
            let c = store.revisionChoice(for: e)
            return "\(e.repoID): " + (c.isPinned ? "\(c.revision.prefix(7)) (from the \(c.source))" : "latest, not pinned")
        }
        return lines.joined(separator: "\n")
            + "\n\nFiles already on the drive are checked and reused; the LocalLM SDK downloads the rest and verifies it."
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete \(pendingDelete[0].repoID) from the library?" : "Delete \(pendingDelete.count) models from the library?"
    }

    private var deleteMessage: String {
        let total = pendingDelete.reduce(0) { $0 + ($1.library?.sizeBytes ?? 0) }.bytes
        let orphaned = pendingDelete.filter { $0.local == nil }.count
        var s = "This frees \(total) on the drive and can't be undone."
        if orphaned > 0 { s += " \(orphaned == 1 ? "It isn't" : "\(orphaned) of them aren't") on this Mac, so you'd have to download \(orphaned == 1 ? "it" : "them") again." }
        return s
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    let store: Store
    @Binding var filter: Filter?
    @State private var targeted: Filter?

    var body: some View {
        List(selection: $filter) {
            Section("Models") {
                ForEach(Filter.modelFilters) { f in
                    let count = store.entries.filter { f.includes($0) }.count
                    Label(f.title, systemImage: f.icon)
                        .badge(count)
                        .help(f == .library ? "Drop models here to back them up to the library"
                              : f == .mac ? "Drop models here to copy them to this Mac" : "")
                        .tag(f)
                        .listRowBackground(targeted == f ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25)) : nil)
                        .modifier(DropTarget(store: store, filter: f, targeted: $targeted))
                }
            }
            Section("History") {
                Label(Filter.activity.title, systemImage: Filter.activity.icon).tag(Filter.activity)
            }
        }
        .listStyle(.sidebar)
    }
}

struct DropTarget: ViewModifier {
    let store: Store
    let filter: Filter
    @Binding var targeted: Filter?

    func body(content: Content) -> some View {
        if filter == .library || filter == .mac {
            content.dropDestination(for: String.self) { ids, _ in
                store.drop(ids, toLibrary: filter == .library)
                return true
            } isTargeted: { on in
                targeted = on ? filter : (targeted == filter ? nil : targeted)
            }
        } else {
            content
        }
    }
}

// MARK: - Header

struct StorageHeader: View {
    let store: Store

    var body: some View {
        HStack(spacing: 24) {
            Meter(title: "Library", icon: "externaldrive", space: store.librarySpace,
                  missing: store.libraryAvailable ? nil : "Not connected")
            Meter(title: "This Mac", icon: "laptopcomputer", space: store.macSpace, missing: nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct Meter: View {
    let title: String
    let icon: String
    let space: Space?
    let missing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: icon).font(.callout.weight(.medium))
                Spacer()
                if let missing {
                    Text(missing).font(.callout).foregroundStyle(.secondary)
                } else if let s = space {
                    Text("\(s.free.bytes) free of \(s.total.bytes)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            let used = space.map { Double($0.total - $0.free) / Double(max($0.total, 1)) } ?? 0
            ProgressView(value: used)
                .tint(used > 0.9 ? .red : used > 0.8 ? .orange : .accentColor)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Banners

struct Banners: View {
    let store: Store

    var body: some View {
        let new = store.entries.filter { $0.status == .newOnMac }
        let repair = store.entries.filter { $0.status == .needsRepair || $0.status == .libraryOutdated }
        let lost = store.entries.filter { $0.status == .brokenLibraryOnly }
        let lostModels = lost.filter(\.isModel)

        VStack(spacing: 8) {
            if store.sameFolder {
                Banner(icon: "exclamationmark.octagon", tint: .red, text: Store.sameFolderMessage,
                       detail: store.libraryHub.path)
            }
            if !store.parkedCopies.isEmpty {
                Banner(icon: "shippingbox", tint: .orange,
                       text: "An older version of Model Shelf left \(store.parkedCopies.count) folder\(store.parkedCopies.count == 1 ? "" : "s") behind after an interrupted copy. \(store.parkedCopies.count == 1 ? "It" : "Each") may hold a model's only copy. Model Shelf won't delete \(store.parkedCopies.count == 1 ? "it" : "them"): check, then move or delete \(store.parkedCopies.count == 1 ? "it" : "them") in Finder.",
                       detail: store.parkedCopies.map(\.path).joined(separator: ", "),
                       action: ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting(store.parkedCopies) }))
            }
            if !store.libraryAvailable {
                Banner(icon: "externaldrive.badge.xmark", tint: .orange,
                       text: "The library isn't available. Connect the drive, or choose another folder in Settings.",
                       detail: store.libraryHub.path)
            }
            if store.libraryAvailable, !new.isEmpty {
                Banner(icon: "tray.and.arrow.down", tint: .accentColor,
                       text: "\(new.count) new download\(new.count == 1 ? "" : "s") (\(new.reduce(0) { $0 + $1.size }.bytes)) \(new.count == 1 ? "isn't" : "aren't") backed up to the library yet.",
                       action: ("Back up all to library", { store.run(.copyToLibrary, on: new.map(\.id)) }))
            }
            if store.libraryAvailable, !repair.isEmpty {
                Banner(icon: "wrench.and.screwdriver", tint: .orange,
                       text: "\(repair.count) library cop\(repair.count == 1 ? "y is" : "ies are") broken or out of date. This Mac has good copies to fix them with.",
                       action: ("Repair all", { store.run(.copyToLibrary, on: repair.map(\.id)) }))
            }
            if !lost.isEmpty {
                Banner(icon: "exclamationmark.triangle", tint: .red,
                       text: "\(lost.count) library cop\(lost.count == 1 ? "y is" : "ies are") broken and \(lost.count == 1 ? "isn't" : "aren't") on this Mac. Download \(lost.count == 1 ? "it" : "them") again to fix.",
                       detail: lost.map(\.repoID).joined(separator: ", "),
                       action: store.libraryAvailable && !lostModels.isEmpty ? ("Redownload all", { store.pendingRedownload = lostModels.map(\.id) }) : nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let text: String
    var detail: String? = nil
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            }
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Table

struct ModelTable: View {
    let store: Store
    let rows: [Entry]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<Entry>]
    @Binding var pendingDelete: [Entry]

    var body: some View {
        Table(of: Entry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.repoID) { e in
                (Text(e.name) + Text("  " + e.org).font(.caption).foregroundStyle(.secondary))
                    .lineLimit(1).truncationMode(.tail)
                    .help(e.repoID)
            }
            .width(min: 200)
            TableColumn("Size", value: \.size) { e in
                Text(e.size.bytes).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Where") { e in Badges(entry: e) }
                .width(150)
            TableColumn("") { e in RowAction(store: store, entry: e) }
                .width(145)
        } rows: {
            ForEach(rows) { e in TableRow(e).draggable(e.id) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: store.entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let e = store.entries.first(where: { ids.contains($0.id) }) { store.reveal(e) }
        }
        .overlay {
            if rows.isEmpty, !store.isScanning {
                ContentUnavailableView("No models here", systemImage: "square.stack.3d.up.slash",
                                       description: Text("Models from the library and the Hugging Face cache show up here."))
            }
        }
    }

    @ViewBuilder
    private func menu(for items: [Entry]) -> some View {
        let groups = Dictionary(grouping: items.compactMap { e in e.primaryAction.map { (e, $0) } }, by: \.1.label)
        ForEach(groups.keys.sorted(), id: \.self) { label in
            let group = groups[label]!
            Button(group.count > 1 ? "\(label) (\(group.count))" : label) {
                if group[0].1.kind == .redownload { store.pendingRedownload = group.map(\.0.id) }
                else { store.run(group[0].1.kind, on: group.map(\.0.id)) }
            }
        }
        let removable = items.filter { $0.status == .synced }
        if !removable.isEmpty, !groups.keys.contains("Remove from Mac") {
            Button("Remove from Mac") { store.run(.removeFromMac, on: removable.map(\.id)) }
        }
        if items.count == 1, let e = items.first {
            Divider()
            Button("Reveal in Finder") { store.reveal(e) }
            Button("Copy repo ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e.repoID, forType: .string)
            }
        }
        let redownloadable = items.filter { $0.isModel && $0.status != .downloading && $0.status != .brokenLibraryOnly }
        if !redownloadable.isEmpty {
            Button("Download again into library…") { store.pendingRedownload = redownloadable.map(\.id) }
        }
        let inLibrary = items.filter { $0.library != nil }
        if !inLibrary.isEmpty {
            Divider()
            Button("Delete from library…", role: .destructive) { pendingDelete = inLibrary }
        }
    }
}

struct Badges: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 4) {
            switch entry.status {
            case .newOnMac: Pill("New on Mac", .accentColor)
            case .downloading: Pill("Downloading", .secondary)
            case .synced: Pill("Library", .secondary); Pill("Mac", .secondary)
            case .libraryOnly: Pill("Library", .secondary)
            case .libraryOutdated: Pill("Library out of date", .orange); Pill("Mac", .secondary)
            case .needsRepair: Pill("Library broken", .orange); Pill("Mac", .secondary)
            case .brokenLibraryOnly: Pill("Library broken", .red)
            case .brokenLocal: Pill("Mac copy broken", .red); if entry.library != nil { Pill("Library", .secondary) }
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        [entry.library.map { "Library: \(describe($0.health))\(rev($0))" }, entry.local.map { "Mac: \(describe($0.health))\(rev($0))" }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func rev(_ r: RepoInfo) -> String {
        r.currentRevision.map { " · revision \($0.prefix(7))" } ?? ""
    }

    private func describe(_ h: RepoHealth) -> String {
        switch h {
        case .ok: "OK"
        case .downloading: "still downloading"
        case .broken(let r): r
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .background((color == .secondary ? Color.secondary : color).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct RowAction: View {
    let store: Store
    let entry: Entry

    var body: some View {
        if store.current?.dirName == entry.id {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) }
        } else if store.isBusy(entry.id) {
            Text("Queued").foregroundStyle(.secondary)
        } else if let a = entry.primaryAction {
            Button(a.label) {
                if a.kind == .redownload { store.pendingRedownload = [entry.id] } else { store.run(a.kind, on: [entry.id]) }
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!store.libraryAvailable)
        }
    }
}

// MARK: - Job bar

struct JobBar: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(store.current?.title ?? "").lineLimit(1).truncationMode(.middle)
                Spacer()
                if !store.queue.isEmpty {
                    Text("\(store.queue.count) more queued").foregroundStyle(.secondary)
                    Button("Clear queue") { store.cancelQueued() }.controlSize(.small)
                }
                Button("Cancel") { store.cancelCurrent() }.controlSize(.small)
            }
            if let p = store.progress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total))
                HStack {
                    switch p.phase {
                    case .downloading:
                        Text("Downloading \(p.done.bytes) of \(p.total.bytes)")
                    case .verifying where store.current?.kind == .redownload:
                        Text("Checking files already on the drive: \(p.done.bytes) of \(p.total.bytes)")
                    default:
                        // Copies check what's already there, then copy and verify what's missing.
                        Text("\(p.phase.rawValue)… \(Int(Double(p.done) / Double(p.total) * 100))%")
                    }
                    Spacer()
                    if store.bytesPerSecond > 0 { Text("\(Int64(store.bytesPerSecond).bytes)/s") }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Activity

struct ActivityView: View {
    let store: Store
    let search: String
    @State private var selection = Set<ActivityEntry.ID>()

    private var rows: [ActivityEntry] {
        store.activity.reversed().filter {
            search.isEmpty || $0.repoID.localizedCaseInsensitiveContains(search) || $0.action.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("When") { e in
                Text(e.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 110, ideal: 120)
            TableColumn("Action") { e in
                HStack(spacing: 6) {
                    switch e.outcome {
                    case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.octagon").foregroundStyle(.red)
                    case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    Text(e.action)
                }
                .help(e.outcome == .succeeded ? e.action : "\(e.outcome.rawValue.capitalized): \(e.detail ?? "")")
            }
            .width(min: 150, ideal: 180)
            TableColumn("Model") { e in
                Text(e.repoID).lineLimit(1).truncationMode(.middle).help(e.repoID)
            }
            TableColumn("Revision") { e in
                if let r = e.revision {
                    Text(Hub.isCommit(r) ? String(r.prefix(7)) : r)
                        .font(.system(.body, design: .monospaced))
                        .help([r, e.revisionSource.map { "from the \($0)" }].compactMap { $0 }.joined(separator: "\n"))
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Size") { e in
                if let b = e.bytes { Text(b.bytes).foregroundStyle(.secondary).monospacedDigit() }
            }
            .width(70)
        }
        .contextMenu(forSelectionType: ActivityEntry.ID.self) { ids in
            if let e = store.activity.first(where: { ids.contains($0.id) }) {
                if let r = e.revision {
                    Button("Copy revision") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(r, forType: .string)
                    }
                }
                if let d = e.detail { Text(d) }
            }
            Divider()
            Button("Show log file in Finder") { store.revealLog() }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Backups, copies, repairs, removals and downloads are recorded here."))
            }
        }
    }
}

// MARK: - First run (sandbox)

/// Shown once in the sandboxed build: Model Shelf can only use folders the user picks.
struct FolderSetupView: View {
    let store: Store

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            VStack(spacing: 8) {
                Text("Choose your model folders").font(.title.weight(.semibold))
                Text("Model Shelf only reads and changes the folders you choose here. You can change them later in Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            VStack(spacing: 0) {
                SetupRow(icon: "laptopcomputer", title: "Hugging Face cache",
                         detail: "Where models download to. Usually ~/.cache/huggingface, a hidden folder.",
                         chosen: store.cacheGranted ? store.cacheHub.path.tildePath : nil) { store.choose(.cache) }
                Divider().padding(.leading, 52)
                SetupRow(icon: "externaldrive", title: "Model library",
                         detail: "A folder on your external drive that holds all your models.",
                         chosen: store.libraryGranted ? store.libraryHub.path.tildePath : nil) { store.choose(.library) }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 560)

            Button("Continue") { store.finishSetup() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!(store.cacheGranted && store.libraryGranted))

            HStack(spacing: 4) {
                Text("Model Shelf collects no data.").foregroundStyle(.secondary)
                Link("Privacy Policy", destination: Links.privacy)
            }
            .font(.footnote)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SetupRow: View {
    let icon: String
    let title: String
    let detail: String
    let chosen: String?
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 26).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if chosen != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let chosen {
                    Text(chosen).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(chosen == nil ? "Choose…" : "Change…", action: choose)
        }
        .padding(14)
    }
}
