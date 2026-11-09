import SwiftUI
import AppKit

// MARK: - Tag engine

enum TagEngine {
    static let sourceExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    static let rawExts: Set<String> = ["arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "dng", "raf",
                                       "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "rwl", "erf", "mos"]

    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func setTags(_ tags: [String], on url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    static func files(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .tagNamesKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    /// Finder's favourite tags (the ones shown in the sidebar / tag menu).
    static func finderFavoriteTags() -> [String] {
        let names = UserDefaults(suiteName: "com.apple.finder")?.array(forKey: "FavoriteTagNames") as? [String] ?? []
        return names.filter { !$0.isEmpty }
    }

    /// Tags currently used by files in a folder.
    static func tagsUsed(in folder: URL) -> [String] {
        var set = Set<String>()
        for f in files(in: folder) { set.formUnion(tags(of: f)) }
        return Array(set)
    }

    struct Match { let jpeg: URL; let raw: URL; let alreadyTagged: Bool }

    static func findMatches(jpegFolder: URL, rawFolder: URL, tag: String) -> (matches: [Match], taggedJPEGs: Int) {
        var rawByBase: [String: [URL]] = [:]
        for f in files(in: rawFolder) where rawExts.contains(f.pathExtension.lowercased()) {
            rawByBase[f.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(f)
        }
        var matches: [Match] = []
        var tagged = 0
        for j in files(in: jpegFolder) where sourceExts.contains(j.pathExtension.lowercased()) {
            guard tags(of: j).contains(tag) else { continue }
            tagged += 1
            for r in rawByBase[j.deletingPathExtension().lastPathComponent.lowercased()] ?? [] {
                matches.append(Match(jpeg: j, raw: r, alreadyTagged: tags(of: r).contains(tag)))
            }
        }
        matches.sort { $0.raw.lastPathComponent.localizedStandardCompare($1.raw.lastPathComponent) == .orderedAscending }
        return (matches, tagged)
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var selectedTag: String { didSet { defaults.set(selectedTag, forKey: "selectedTag") } }
    @Published var jpegFolder: URL? { didSet { defaults.set(jpegFolder?.path, forKey: "jpegFolder"); refreshTags(); clear() } }
    @Published var rawFolder: URL? { didSet { defaults.set(rawFolder?.path, forKey: "rawFolder"); clear() } }
    @Published var availableTags: [String] = []
    @Published var matches: [TagEngine.Match] = []
    @Published var status = ""
    @Published var busy = false
    @Published var previewed = false

    init() {
        selectedTag = defaults.string(forKey: "selectedTag") ?? ""
        let fm = FileManager.default
        if let p = defaults.string(forKey: "jpegFolder"), fm.fileExists(atPath: p) { jpegFolder = URL(fileURLWithPath: p) }
        if let p = defaults.string(forKey: "rawFolder"), fm.fileExists(atPath: p) { rawFolder = URL(fileURLWithPath: p) }
        refreshTags()
    }

    var pendingCount: Int { matches.filter { !$0.alreadyTagged }.count }

    func clear() { matches = []; previewed = false; status = "" }

    func refreshTags() {
        let favs = TagEngine.finderFavoriteTags()
        let folder = jpegFolder
        Task.detached(priority: .userInitiated) {
            let used = folder.map(TagEngine.tagsUsed) ?? []
            let extra = used.filter { !favs.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            await MainActor.run {
                self.availableTags = favs + extra
                if self.selectedTag.isEmpty || !self.availableTags.contains(self.selectedTag) {
                    self.selectedTag = self.availableTags.first(where: { used.contains($0) }) ?? self.availableTags.first ?? ""
                }
            }
        }
    }

    func pick(raw: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = raw ? "Choose the RAW folder" : "Choose the JPEG folder"
        if let start = raw ? (rawFolder ?? jpegFolder?.deletingLastPathComponent()) : jpegFolder {
            panel.directoryURL = start
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if raw { rawFolder = url } else {
            jpegFolder = url
            // Convenience: auto-fill a sibling "RAW" folder if there is one.
            let sibling = url.deletingLastPathComponent().appendingPathComponent("RAW")
            if rawFolder == nil, FileManager.default.fileExists(atPath: sibling.path) { rawFolder = sibling }
        }
    }

    func preview() {
        guard let j = jpegFolder, let r = rawFolder, !selectedTag.isEmpty else { return }
        let tag = selectedTag
        busy = true
        Task.detached(priority: .userInitiated) {
            let result = TagEngine.findMatches(jpegFolder: j, rawFolder: r, tag: tag)
            await MainActor.run {
                self.matches = result.matches
                self.previewed = true
                self.busy = false
                let already = result.matches.count - self.pendingCount
                self.status = "\(result.taggedJPEGs) JPEGs tagged “\(tag)” · \(result.matches.count) RAW matches · \(self.pendingCount) to tag"
                    + (already > 0 ? " · \(already) already tagged" : "")
            }
        }
    }

    func apply() {
        let tag = selectedTag
        let todo = matches.filter { !$0.alreadyTagged }
        guard !todo.isEmpty else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            var ok = 0, failed: [String] = []
            for m in todo {
                var t = TagEngine.tags(of: m.raw)
                if !t.contains(tag) { t.append(tag) }
                do { try TagEngine.setTags(t, on: m.raw); ok += 1 }
                catch { failed.append(m.raw.lastPathComponent) }
            }
            let j = todo[0].jpeg.deletingLastPathComponent(), r = todo[0].raw.deletingLastPathComponent()
            let refreshed = TagEngine.findMatches(jpegFolder: j, rawFolder: r, tag: tag)
            let done = ok, errs = failed
            await MainActor.run {
                self.busy = false
                self.matches = refreshed.matches
                self.status = "✓ Tagged \(done) RAW file\(done == 1 ? "" : "s") with “\(tag)”"
                    + (errs.isEmpty ? "" : " · \(errs.count) failed: \(errs.prefix(5).joined(separator: ", "))")
            }
        }
    }
}

// MARK: - UI

struct FolderRow: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(url == nil ? Color.secondary : Color.accentColor)
                Text(url?.path(percentEncoded: false) ?? "No folder chosen")
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .onTapGesture(perform: action)
            .help(url?.path ?? "")
            Button("Choose…", action: action)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FolderRow(title: "JPEG folder", url: model.jpegFolder) { model.pick(raw: false) }
            FolderRow(title: "RAW folder", url: model.rawFolder) { model.pick(raw: true) }

            HStack(spacing: 10) {
                Text("Tag").frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                Picker("", selection: $model.selectedTag) {
                    ForEach(model.availableTags, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .onChange(of: model.selectedTag) { model.clear() }
                Button { model.refreshTags() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload tags")
            }

            Divider()

            HStack {
                Button("Preview") { model.preview() }
                    .keyboardShortcut("p")
                Button("Apply Tags to RAW") { model.apply() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.previewed || model.pendingCount == 0)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .disabled(model.busy || model.jpegFolder == nil || model.rawFolder == nil || model.selectedTag.isEmpty)

            if !model.status.isEmpty {
                Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            List(model.matches, id: \.raw) { m in
                HStack {
                    Image(systemName: m.alreadyTagged ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(m.alreadyTagged ? .green : .orange)
                    Text(m.raw.lastPathComponent).monospaced()
                    Spacer()
                    Text(m.alreadyTagged ? "tagged" : "pending").font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.raw]) }
                }
            }
            .overlay {
                if model.matches.isEmpty {
                    Text(model.previewed ? "No matching RAW files" : "Choose folders and a tag, then Preview")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
    }
}

@main
struct TagSyncApp: App {
    var body: some Scene {
        WindowGroup("TagSync") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
