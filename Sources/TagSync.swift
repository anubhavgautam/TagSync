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
    private var generation = 0

    @Published var selectedTag: String {
        didSet { guard oldValue != selectedTag else { return }; defaults.set(selectedTag, forKey: "selectedTag"); recompute() }
    }
    @Published var jpegFolder: URL? {
        didSet { defaults.set(jpegFolder?.path, forKey: "jpegFolder"); refreshTags(); recompute() }
    }
    @Published var rawFolder: URL? {
        didSet { defaults.set(rawFolder?.path, forKey: "rawFolder"); recompute() }
    }
    @Published var availableTags: [String] = []
    @Published var matches: [TagEngine.Match] = []
    @Published var taggedJPEGs = 0
    @Published var busy = false
    @Published var message: String?

    init() {
        selectedTag = defaults.string(forKey: "selectedTag") ?? ""
        let fm = FileManager.default
        if let p = defaults.string(forKey: "jpegFolder"), fm.fileExists(atPath: p) { jpegFolder = URL(fileURLWithPath: p) }
        if let p = defaults.string(forKey: "rawFolder"), fm.fileExists(atPath: p) { rawFolder = URL(fileURLWithPath: p) }
        refreshTags()
        recompute()
    }

    var pending: [TagEngine.Match] { matches.filter { !$0.alreadyTagged } }
    var ready: Bool { jpegFolder != nil && rawFolder != nil && !selectedTag.isEmpty }

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

    /// Live result, Numi-style: re-run the match whenever an input changes.
    func recompute(keepMessage: Bool = false) {
        if !keepMessage { message = nil }
        guard let j = jpegFolder, let r = rawFolder, !selectedTag.isEmpty else {
            matches = []; taggedJPEGs = 0; return
        }
        generation += 1
        let gen = generation, tag = selectedTag
        Task.detached(priority: .userInitiated) {
            let result = TagEngine.findMatches(jpegFolder: j, rawFolder: r, tag: tag)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.matches = result.matches
                self.taggedJPEGs = result.taggedJPEGs
            }
        }
    }

    func pick(raw: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = raw ? "Choose the RAW folder" : "Choose the JPEG folder"
        panel.directoryURL = raw ? (rawFolder ?? jpegFolder?.deletingLastPathComponent()) : jpegFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(url, raw: raw)
    }

    func set(_ url: URL, raw: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        if raw { rawFolder = url; return }
        jpegFolder = url
        // Convenience: auto-fill a sibling "RAW" folder if there is one.
        let sibling = url.deletingLastPathComponent().appendingPathComponent("RAW")
        if rawFolder == nil, FileManager.default.fileExists(atPath: sibling.path) { rawFolder = sibling }
    }

    func apply() {
        let tag = selectedTag
        let todo = pending
        guard !todo.isEmpty, !busy else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            var ok = 0, failed = 0
            for m in todo {
                var t = TagEngine.tags(of: m.raw)
                if !t.contains(tag) { t.append(tag) }
                do { try TagEngine.setTags(t, on: m.raw); ok += 1 } catch { failed += 1 }
            }
            let done = ok, errs = failed
            await MainActor.run {
                self.busy = false
                self.message = "✓ tagged \(done)" + (errs > 0 ? " · \(errs) failed" : "")
                self.recompute(keepMessage: true)
            }
        }
    }
}

// MARK: - Look

enum Palette {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static let background = dynamic(0xF7F6F3, 0x1E1E1E)
    static let text       = dynamic(0x2B2B2B, 0xE6E6E6)
    static let label      = dynamic(0x9A9894, 0x7C7C7C)
    static let result     = dynamic(0x3F9C6B, 0x7FCF9B)   // calm green for live values
    static let accent     = dynamic(0xC84520, 0xF76337)   // Quintessence orange
    static let rule       = dynamic(0xE6E4DF, 0x2C2C2C)
}

extension Font {
    static let sheet = Font.system(size: 15, weight: .regular)
    static let sheetMono = Font.system(size: 12.5, weight: .regular, design: .monospaced)
}

// MARK: - UI

/// One "line" of the sheet: quiet label on the left, live value on the right.
struct SheetLine<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Palette.label)
            Spacer(minLength: 0)
            value
        }
        .font(.sheet)
        .frame(height: 26)
    }
}

struct FolderLine: View {
    let label: String
    let url: URL?
    let pick: () -> Void
    let drop: (URL) -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        SheetLine(label: label) {
            Button(action: pick) {
                Text(url.map(Self.short) ?? "choose…")
                    .foregroundStyle(url == nil ? Palette.label : Palette.result)
                    .underline(hovering, color: Palette.result.opacity(0.4))
                    .lineLimit(1).truncationMode(.head)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(url?.path ?? "Click or drop a folder")
        }
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.result.opacity(targeted ? 0.12 : 0)))
        .padding(.horizontal, -6)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            drop(u); return true
        } isTargeted: { targeted = $0 }
    }

    /// "…/Shiminami Kaido/JPEG" — the last two path components read best in a narrow window.
    static func short(_ url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "/")
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    static let titleBarHeight: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderLine(label: "jpeg", url: model.jpegFolder, pick: { model.pick(raw: false) },
                       drop: { model.set($0, raw: false) })
            FolderLine(label: "raw", url: model.rawFolder, pick: { model.pick(raw: true) },
                       drop: { model.set($0, raw: true) })
            SheetLine(label: "tag") {
                Menu {
                    ForEach(model.availableTags, id: \.self) { t in
                        Button(t) { model.selectedTag = t }
                    }
                    Divider()
                    Button("Reload Tags") { model.refreshTags() }
                } label: {
                    Text(model.selectedTag.isEmpty ? "choose…" : model.selectedTag)
                        .font(.sheet)
                        .foregroundStyle(model.selectedTag.isEmpty ? Palette.label : Palette.result)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Rectangle().fill(Palette.rule).frame(height: 1).padding(.vertical, 8)

            SheetLine(label: "jpegs tagged") { count(model.taggedJPEGs) }
            SheetLine(label: "raw matches") { count(model.matches.count) }
            SheetLine(label: "already tagged") { count(model.matches.count - model.pending.count) }

            fileList
                .padding(.vertical, 8)

            Rectangle().fill(Palette.rule).frame(height: 1)

            HStack(alignment: .firstTextBaseline) {
                Text(model.message ?? "to tag")
                    .font(.sheet)
                    .foregroundStyle(model.message == nil ? Palette.label : Palette.result)
                Spacer()
                if model.busy { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button(action: model.apply) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(model.pending.count)")
                            .font(.system(size: 26, weight: .medium).monospacedDigit())
                        Text("↩").font(.system(size: 13, weight: .semibold)).opacity(0.7)
                    }
                    .foregroundStyle(model.pending.isEmpty ? Palette.label : Palette.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(model.pending.isEmpty || model.busy)
                .help("Tag \(model.pending.count) RAW file(s) — press Return")
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 22)
        .padding(.top, 40)        // clears the traffic lights
        .padding(.bottom, 16)
        .foregroundStyle(Palette.text)
        .frame(width: 360, height: 360)
        .background(Palette.background)
        .ignoresSafeArea()
        // The hidden title bar still reserves its height below the safe area; size the
        // window's content so the whole window (title bar included) is a 360pt square.
        .frame(width: 360, height: 360 - Self.titleBarHeight, alignment: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recompute(keepMessage: true)   // pick up tags changed in Finder meanwhile
        }
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)").monospacedDigit().foregroundStyle(model.ready ? Palette.result : Palette.label)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(model.matches, id: \.raw) { m in
                    HStack {
                        Text(m.raw.lastPathComponent)
                        Spacer()
                        Text(m.alreadyTagged ? "✓" : "+")
                            .foregroundStyle(m.alreadyTagged ? Palette.result : Palette.accent)
                    }
                    .font(.sheetMono)
                    .foregroundStyle(Palette.label)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.raw]) }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .overlay {
            if model.matches.isEmpty {
                Text(model.ready ? "no matching raw files" : "drop folders above")
                    .font(.sheetMono).foregroundStyle(Palette.label.opacity(0.7))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TagSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("TagSync", id: "main") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
    }
}
